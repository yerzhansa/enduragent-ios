import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test func aSecondApprovedWorkoutInTheSameTurnGetsANewIdentity() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let fixture = await fixture(url: url)
		let held = HeldClock()
		defer { held.release(.seconds(11)) }
		fixture.model.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						#"{"date":"1998-06-14","name":"Morning","description":"Three sets"}"#),
				.finish(reason: .toolCalls),
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						#"{"date":"1998-06-14","name":"Evening","description":"Four sets"}"#),
				.finish(reason: .toolCalls), .text("Both reviews are ready."), .hang,
			], for: .chat, otherwise: fixture.model.respond)
		let model = HeldApprovalTransport(base: fixture.model, clock: held) { index, _ in
			index == 2 ? .seconds(11) : nil
		}
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: fixture.store), secrets: keyedSecrets(),
					models: ModelService { _ in model },
					training: .fake { _, _ in fixture.client }, credits: .fake(FakeCreditsClient()),
					host: ImmediateExecutionHost(), clock: clock),
				builtInModel: testModel, deviceLanguage: .en,
				coalescing: CoalescingPolicy(window: .zero)))
		let turn = try #require(
			try await coach.send(draft("Add morning and evening workouts"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(11))
		let firstReview = try #require(await coach.currentSnapshot(.main)?.review)
		_ = await coach.decide(.presented(firstReview.ref), in: .main)
		let first = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = await coach.decide(.approve(first), in: .main)
		held.release(.seconds(11))
		await coach.waitForLiveText(turn)
		let secondReview = try #require(await coach.currentSnapshot(.main)?.review)
		_ = await coach.decide(.presented(secondReview.ref), in: .main)
		let second = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = await coach.decide(.approve(second), in: .main)
		await coach.stop(.main)
		#expect(server.posts.count == 2)
		#expect(server.events.count == 2)
		#expect(
			Set(server.events.compactMap { $0["name"]?.stringValue }) == ["Morning", "Evening"])
		let identifiers = server.posts.compactMap { $0.body.objectFields["uid"]?.stringValue }
		#expect(Set(identifiers).count == 2)
		let state = try #require(await coach.settledState(of: turn, in: .main))
		guard case .interrupted(let stopped) = state else {
			Issue.record("expected the stopped turn")
			return
		}
		#expect(stopped.saved.calendarWrites == 2)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: fixture.store)
		#expect(await coach.currentSnapshot(.main) == reopened.currentSnapshot(.main))
	}
}
