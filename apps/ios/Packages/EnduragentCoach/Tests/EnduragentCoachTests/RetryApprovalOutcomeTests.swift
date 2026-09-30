import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test func uncertainApprovalDuringBackoffSettlesUnverifiedWork() async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(base: base, clock: held, failure: URLError(.timedOut))
		transport.script =
			workoutProposal
			+ [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let coach = heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await held.waitUntilHeld(.seconds(13))
		held.release(.seconds(7))
		for _ in 0..<1_000 { await Task.yield() }
		held.release(.seconds(13))
		guard case .uncertain = await approving.value else {
			Issue.record("expected an uncertain calendar write")
			return
		}
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .savedWork(let saved) = settled else {
			Issue.record("expected saved work, got \(settled)")
			return
		}
		#expect(saved.outcome == .savedUnverified)
		#expect(saved.saved.calendarWrites == 1)
		#expect(saved.notice.action == nil)
		#expect(!settled.retryable)
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 2)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.count == 1)
	}

	@Test func stopDuringPendingApprovalPreservesSavedWrite() async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(base: base, clock: held)
		transport.script =
			workoutProposal
			+ [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
		let coach = heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await held.waitUntilHeld(.seconds(13))
		let stopping = Task { await coach.stop(.main) }
		for _ in 0..<1_000 { await Task.yield() }
		held.release(.seconds(13))
		#expect(
			await approving.value
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		await stopping.value
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected interruption, got \(settled)")
			return
		}
		#expect(interrupted.saved.calendarWrites == 1)
		#expect(!settled.retryable)
		#expect(base.calls.filter(\.isWrite).count == 1)
	}

	@Test func rejectedApprovalDuringBackoffAllowsRetry() async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(
			base: base, clock: held,
			failure: IntervalsError(code: "http", details: "Rejected", status: 422))
		transport.script =
			workoutProposal
			+ [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let coach = heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await held.waitUntilHeld(.seconds(13))
		held.release(.seconds(7))
		held.release(.seconds(13))
		guard case .partiallyApplied = await approving.value else {
			Issue.record("expected a definite rejection")
			return
		}
		#expect(replyText(try #require(await settledTurn(turn, on: coach))) == "Second.")
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.count == 2)
		#expect(base.calls.filter(\.isWrite).isEmpty)
		let retryToken = try await presentReview(on: coach)
		#expect(
			await coach.decide(.approve(retryToken), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(base.calls.filter(\.isWrite).count == 1)
	}

	@Test func pendingApprovalDuringRetryModelRequestBlocksAnotherProposal() async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(base: base, clock: held)
		transport.script =
			workoutProposal
			+ [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			request.charge == .chatAttempt && index == 3 ? .seconds(11) : nil
		}
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		held.release(.seconds(7))
		try await held.waitUntilHeld(.seconds(11))
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await held.waitUntilHeld(.seconds(13))
		held.release(.seconds(11))
		for _ in 0..<1_000 { await Task.yield() }
		held.release(.seconds(13))
		try await expectSingleApproval(
			turn: turn, first: await approving.value, coach: coach, intervals: base,
			savedRequests: 3)
	}
}
