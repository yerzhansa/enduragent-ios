import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(arguments: ApprovalCheckpoint.allCases)
	func uncertainApprovalDuringBackoffSettlesUnverifiedWork(checkpoint: ApprovalCheckpoint)
		async throws
	{
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(base: base, clock: held, failure: URLError(.timedOut))
		transport.script =
			workoutProposal
			+ [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			request.charge == .chatAttempt && index == 3 ? .seconds(11) : nil
		}
		let coach = await heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		try await checkpoint.reach(using: held)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await held.waitUntilHeld(.seconds(13))
		try await expectApprovalBlocked(
			at: checkpoint, turn: turn, coach: coach, model: model, clock: held)
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
		#expect(saved.saved.unverifiedCalendarWrites == 1)
		#expect(saved.notice.action == nil)
		#expect(
			saved.notice.sentence(in: LanguageTag.en.phrasebook)
				== "The calendar change may have been saved. Check your calendar before asking again."
		)
		#expect(!settled.retryable)
		#expect(
			await coach.currentSnapshot(.main)?.review?.notice?.key == Catalog.reviewWritePending)
		#expect(
			transport.requests.filter { $0.charge == .chatAttempt }.count == checkpoint.requests)
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
		let coach = await heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await held.waitUntilHeld(.seconds(13))
		defer { held.release(.seconds(13)) }
		let stopping = Task { await coach.stop(.main) }
		let settled = try #require(await settledTurn(turn, on: coach))
		held.release(.seconds(13))
		#expect(
			await approving.value
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		await stopping.value
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected interruption, got \(settled)")
			return
		}
		#expect(interrupted.saved.calendarWrites == 1)
		#expect(!settled.retryable)
		#expect(base.calls.filter(\.isWrite).count == 1)
	}

	@Test func dispatchedRejectionDuringBackoffBlocksRegeneration() async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(
			base: base, clock: held,
			failure: IntervalsError(code: "http", details: "Rejected", status: 422))
		transport.script =
			workoutProposal
			+ [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let coach = await heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await held.waitUntilHeld(.seconds(13))
		held.release(.seconds(7))
		held.release(.seconds(13))
		guard case .uncertain = await approving.value else {
			Issue.record("a dispatched rejection stays unknown")
			return
		}
		let settled = try #require(await settledTurn(turn, on: coach))
		#expect(!settled.retryable)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.count == 1)
		#expect(base.calls.filter(\.isWrite).isEmpty)

	}

	@Test(arguments: ApprovalCheckpoint.allCases)
	func pendingApprovalDuringRetryModelRequestBlocksAnotherProposal(checkpoint: ApprovalCheckpoint)
		async throws
	{
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
		let coach = await heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		try await checkpoint.reach(using: held)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await held.waitUntilHeld(.seconds(13))
		try await expectApprovalBlocked(
			at: checkpoint, turn: turn, coach: coach, model: model, clock: held)
		held.release(.seconds(13))
		try await expectSingleApproval(
			turn: turn, first: await approving.value, coach: coach, intervals: base,
			savedRequests: checkpoint.requests)
	}
}
