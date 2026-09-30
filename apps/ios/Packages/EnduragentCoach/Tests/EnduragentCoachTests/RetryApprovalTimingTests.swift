import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(arguments: [true, false])
	func approvalDuringRetryModelRequestSettlesSavedWork(proposesAgain: Bool) async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ (proposesAgain ? workoutProposal : []) + [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			request.charge == .chatAttempt && index == 3 ? .seconds(11) : nil
		}
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		held.release(.seconds(7))
		try await held.waitUntilHeld(.seconds(11))
		let first = await coach.decide(.approve(token), in: .main)
		held.release(.seconds(11))
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach, intervals: intervals, savedRequests: 3)
	}

	@Test func approvalDuringBackoffWaitsForCalendarWrite() async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(base: base, clock: held)
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { _, _ in nil }
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await held.waitUntilHeld(.seconds(13))
		held.release(.seconds(7))
		let waiting = try #require(await coach.currentSnapshot(.main)?.turns.first)
		#expect(!waiting.state.isSettled)
		held.release(.seconds(13))
		let first = await approving.value
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach, intervals: base, savedRequests: 2)
	}

	@Test func approvalDuringOverflowFlushSettlesSavedWork() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let overflow = ScriptedFailure.http(
			status: 400, body: #"{"error":{"message":"maximum context length exceeded"}}"#)
		transport.script =
			workoutProposal + [.fail(overflow)] + workoutProposal + [
				.text("Second."), .finish(reason: .stop),
			]
		let model = HeldApprovalTransport(base: transport, clock: held) { _, request in
			request.charge == .memoryFlush || request.charge == .compaction ? .seconds(17) : nil
		}
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(17))
		let token = try await presentReview(on: coach)
		let first = await coach.decide(.approve(token), in: .main)
		held.release(.seconds(17))
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach, intervals: intervals, savedRequests: 2)
	}

	@Test func approvalThenStopDuringBackoffWritesOnce() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { _, _ in nil }
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let first = await coach.decide(.approve(token), in: .main)
		await coach.stop(.main)
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach, intervals: intervals)
	}

	@Test func stopThenApprovalDuringBackoffWritesOnce() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { _, _ in nil }
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		await coach.stop(.main)
		let first = await coach.decide(.approve(token), in: .main)
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach, intervals: intervals)
	}

	@Test func approvalAfterTerminalFailureWritesOnce() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.script = workoutProposal + [.fail(.http(status: 401))]
		let model = HeldApprovalTransport(base: transport, clock: held) { _, _ in nil }
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		_ = await settledTurn(turn, on: coach)
		let token = try await presentReview(on: coach)
		let first = await coach.decide(.approve(token), in: .main)
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach, intervals: intervals)
	}

	@Test func approvalBeforeRateLimitSettlesSavedWork() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ workoutProposal + [.text("Second."), .finish(reason: .stop)]
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			request.charge == .chatAttempt && index == 2 ? .seconds(19) : nil
		}
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(19))
		let token = try await presentReview(on: coach)
		let first = await coach.decide(.approve(token), in: .main)
		held.release(.seconds(19))
		try await expectSingleApproval(
			turn: turn, first: first, coach: coach, intervals: intervals, savedRequests: 2)
	}

	func heldApprovalCoach(
		_ held: HeldClock, model: any ModelTransport, intervals: any IntervalsClient,
		records: (any RecordLog)? = nil
	) -> Coach {
		Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: records ?? store), secrets: keyedSecrets(),
				models: ModelService { _ in model }, training: .fake { _, _ in intervals },
				credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: held),
			builtInModel: testModel, deviceLanguage: .en,
			coalescing: CoalescingPolicy(window: .zero))
	}

	func expectSingleApproval(
		turn: TurnID, first: ReviewOutcome, coach: Coach,
		intervals: FakeIntervalsClient, savedRequests: Int? = nil
	) async throws {
		let settled = try #require(await settledTurn(turn, on: coach))
		let proposals = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.pendingProposal]))
		).records.count
		#expect(first == .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(proposals == 1)
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(intervals.calls.filter(\.isWrite).count == 1)
		if let savedRequests {
			guard case .savedWork(let saved) = settled else {
				Issue.record("expected saved work, got \(settled)")
				return
			}
			#expect(
				transport.requests.filter { $0.charge == .chatAttempt }.count
					== savedRequests)
			#expect(saved.outcome == .writesSaved)
			#expect(saved.saved.calendarWrites == 1)
			#expect(saved.notice.action == nil)
			#expect(!settled.retryable)
		}
	}
}
