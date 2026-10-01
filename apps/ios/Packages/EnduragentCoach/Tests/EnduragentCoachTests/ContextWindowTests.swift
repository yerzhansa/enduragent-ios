import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ContextWindowTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let earlierSummary = "## Athlete Profile\n- Rides Saturdays with a group"

	@Test func contextWindowOverrideShrinksTheHistoryBudget() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) / 2)
		transport.respond = ScriptedReply.sequence(
			[.text(earlierSummary), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[
				.text("Thursday is on."), .finish(reason: .stop), .text("Saturday too."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Is Thursday on?")
		#expect(sent(.droppedSummary, by: transport).isEmpty)
		try await coach.setSession(
			SessionSettings.npmDefaults.replacing(.contextWindowOverride, with: "100000"))
		_ = try await coach.sendAndSettle("And Saturday?")
		#expect(sent(.droppedSummary, by: transport).count == 1)
		#expect(sent(.compaction, by: transport).isEmpty)
	}

	@Test func aSmallerContextWindowCompactsBeforeTheCall() async throws {
		try await seedHistory(store, clock: clock, turns: 5, tokens: 2_500)
		transport.respond = ScriptedReply.sequence(
			[.text(earlierSummary), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Is Thursday on?")
		#expect(transport.requests.map(\.charge) == [.chatAttempt])
		let window = systemTokens(clock: clock) + TurnPolicy.reserveTokens + 1_500
		try await coach.setSession(
			SessionSettings.npmDefaults.replacing(.contextWindowOverride, with: String(window)))
		transport.respond = ScriptedReply.sequence(
			[.text("Saturday too."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let settled = try await coach.sendAndSettle("And Saturday?")
		#expect(replyText(settled) == "Saturday too.")
		#expect(
			transport.requests.map(\.charge) == [
				.chatAttempt, .memoryFlush, .compaction, .chatAttempt,
			])
	}

	@Test func aFinishAtTheOverriddenWindowIsRescuedAsAnOverflow() async throws {
		transport.finishUsage = Usage(inputTokens: 60_000, outputTokens: 8, cost: nil)
		transport.respond = ScriptedReply.sequence(
			[
				.text("truncated"), .finish(reason: .length), .text("after compact"),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		try await coach.setSession(
			SessionSettings.npmDefaults.replacing(.contextWindowOverride, with: "50000"))
		let rescued = try await coach.sendAndSettle("Long history")
		#expect(replyText(rescued) == "after compact")
		#expect(sent(.chatAttempt, by: transport).count == 2)
	}

	private func makeCoach() async -> Coach {
		await EnduragentCoachTests.makeCoach(transport: transport, store: store, clock: clock)
	}
}
