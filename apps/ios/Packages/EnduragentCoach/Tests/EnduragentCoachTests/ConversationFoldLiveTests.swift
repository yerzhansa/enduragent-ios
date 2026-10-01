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
		transport.summaryScript = [.text("Earlier conversation."), .finish(reason: .stop)]
		switch ending {
		case .reply: transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		case .stop: transport.script = [.text("Thursday is"), .hang]
		case .failure: transport.script = [.fail(.http(status: 400))]
		}
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
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
