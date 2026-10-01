import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test func approvalDuringBackoffSettlesSavedWork() async throws {
		try await approvalDuringWaitSettlesSavedWork(timeout: false)
	}

	@Test func approvalBeforeTimeoutFailureSettlesSavedWork() async throws {
		try await approvalDuringWaitSettlesSavedWork(timeout: true)
	}

	private func approvalDuringWaitSettlesSavedWork(timeout: Bool) async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [
				.fail(
					timeout
						? .connection(.timedOut) : .http(status: 429, headers: ["retry-after": "7"])
				)
			] + workoutProposal + [.text("A second workout is ready."), .finish(reason: .stop)],
			for: .chat, otherwise: transport.respond)
		let coach = await approvalCoach(held, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add a ride tomorrow"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(await coach.decide(.approve(token), in: .main) == .staleControl)
		held.release(.seconds(7))
		let snapshots = await coach.observe(.main)
		for await snapshot in snapshots {
			guard let settled = snapshot.turns.first(where: { $0.id == turn })?.state,
				settled.isSettled
			else { continue }
			#expect(
				intervals.calls.filter(\.isWrite) == [
					.createEvent(
						date: "1998-06-14", externalId: "cycling-coach:1998-06-14:endurance")
				])
			#expect(snapshot.review == nil)
			#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 2)
			let proposals = try await store.fetch(
				RecordQuery(scope: .deviceLocal([.pendingProposal])))
			#expect(proposals.records.count == 1)
			guard case .savedWork(let savedWork) = settled else {
				Issue.record("expected saved work, got \(settled)")
				return
			}
			#expect(savedWork.outcome == .writesSaved)
			#expect(
				savedWork.saved
					== WriteSummary(
						memorySections: 0, ledgerEvents: 0, planSaves: 0, calendarWrites: 1))
			#expect(savedWork.notice.action == nil)
			#expect(!settled.retryable)
			await #expect(throws: RetryRefusal.alreadyAnswered) {
				try await coach.retry(turn, in: .main)
			}
			let reopened = await approvalCoach(HeldClock(), intervals: intervals)
			#expect(await reopened.currentSnapshot(.main)?.turns.first?.state == settled)
			return
		}
		Issue.record("conversation observation ended before settlement")
	}

	@Test func approvalFromEarlierTurnDoesNotSettleWaitingTurn() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let coach = await approvalCoach(held, intervals: intervals)
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [.text("Please review the ride."), .finish(reason: .stop)],
			for: .chat, otherwise: transport.respond)
		let earlier = try #require(
			try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		#expect(
			replyText(try #require(await settledTurn(earlier, on: coach)))
				== "Please review the ride.")
		let token = try await presentReview(on: coach)
		transport.respond = ScriptedReply.sequence(
			[
				.fail(.http(status: 429, headers: ["retry-after": "7"])),
				.text("Rest today."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let waiting = try #require(
			try await coach.send(draft("What about today?"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		held.release(.seconds(7))
		#expect(replyText(try #require(await settledTurn(waiting, on: coach))) == "Rest today.")
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 4)
		#expect(intervals.calls.filter(\.isWrite).count == 1)
	}

	@Test func canceledReviewDuringBackoffDoesNotSettleSavedWork() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let coach = await approvalCoach(held, intervals: intervals)
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [
				.fail(.http(status: 429, headers: ["retry-after": "7"])),
				.text("Rest today."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		#expect(await coach.decide(.cancel(token), in: .main) == .canceled(kept: []))
		held.release(.seconds(7))
		#expect(replyText(try #require(await settledTurn(turn, on: coach))) == "Rest today.")
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 3)
		#expect(intervals.calls.filter(\.isWrite).isEmpty)
	}

	var workoutProposal: [ScriptedEvent] {
		[
			.toolCall(
				name: "intervals_create_workout",
				arguments:
					#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
			),
			.finish(reason: .toolCalls),
		]
	}

	private func approvalCoach(_ held: HeldClock, intervals: FakeIntervalsClient) async -> Coach {
		let model = ApprovalWaitTransport(base: transport, clock: held)
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: store), secrets: keyedSecrets(),
				models: ModelService { _ in model }, training: .fake { _, _ in intervals },
				credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: held),
			builtInModel: testModel, deviceLanguage: .en,
			coalescing: CoalescingPolicy(window: .zero))
		return await consentingCoach(coach)
	}

	func presentReview(on coach: Coach) async throws -> ReviewControlToken {
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		return try #require(await coach.currentSnapshot(.main)?.review?.token)
	}

	func settledTurn(_ turn: TurnID, on coach: Coach) async -> TurnState? {
		await coach.settledState(of: turn, in: .main)
	}
}

private struct ApprovalWaitTransport: ModelTransport {
	let base: FakeModelTransport
	let clock: HeldClock

	func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error> {
		let source = base.stream(request)
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					for try await event in source {
						continuation.yield(event)
					}
					continuation.finish()
				} catch {
					do {
						if case ProviderFailure.timeout = error {
							try await clock.sleep(for: .seconds(7))
						}
						continuation.finish(throwing: error)
					} catch {
						continuation.finish(throwing: error)
					}
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}
