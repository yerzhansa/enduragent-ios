import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension ConversationFoldTests {
	enum TrimmedAttemptEnd: CaseIterable, Sendable {
		case reply
		case stop
		case failure
	}

	@Test(arguments: TrimmedAttemptEnd.allCases)
	func liveTrimMatchesReload(ending: TrimmedAttemptEnd) async throws {
		let store = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let seeded = try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier conversation."), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		switch ending {
		case .reply:
			transport.respond = ScriptedReply.sequence(
				[.text("Thursday is on."), .finish(reason: .stop)], otherwise: transport.respond)
		case .stop:
			transport.respond = ScriptedReply.sequence(
				[.text("Thursday is"), .hang], otherwise: transport.respond)
		case .failure:
			transport.respond = ScriptedReply.sequence(
				[.fail(.http(status: 400))], otherwise: transport.respond)
		}
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let turn = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		if ending == .stop {
			await coach.waitForLiveText(turn)
			await coach.stop(.main)
		}
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		switch ending {
		case .reply: #expect(replyText(settled) == "Thursday is on.")
		case .stop: #expect(isInterrupted(settled))
		case .failure: #expect(failure(settled) != nil)
		}
		let mailbox = await coach.mailbox(for: .main)
		let live = await mailbox.conversation.current.promptHistory(excluding: nil)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let reloaded = try await ledger.conversation(.main).current.promptHistory(excluding: nil)
		#expect(live.summary == "Earlier conversation.")
		#expect(live.ulids == reloaded.ulids)
		let matchesReload = live == reloaded
		#expect(matchesReload)
		#expect(!live.ulids.contains(try #require(seeded.first).user))
	}
}
