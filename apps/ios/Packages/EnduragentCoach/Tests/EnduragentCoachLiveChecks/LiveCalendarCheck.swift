#if os(macOS)
	import Foundation
	import Testing

	@testable import EnduragentCoach

	@Suite(.serialized) struct LiveCalendarCheck {
		@Test(.enabled(if: LiveCheck.selected == .calendar), .timeLimit(.minutes(10)))
		func writesTheTestCalendarThroughTheAppsWriteCall() async throws {
			let started = Date()
			let key: String
			let ledger: LiveSeedLedger
			do {
				key = try #require(
					try LiveKey.secrets([.intervals], lookUp: LiveKey.lookUpInKeychain)[.intervals])
				ledger = try LiveSeedLedger(file: try LiveCalendarRun.ledgerFile())
			} catch let stop as LiveCheckStop {
				Issue.record(Comment(rawValue: stop.description))
				return
			}
			let client = IntervalsRESTClient(
				credential: .apiKey(key), session: LiveResponseTap.session())
			var run = LiveCalendarRun(
				account: IntervalsSeedAccount(client: client),
				plan: try LiveCalendarPlan(
					today: IntervalsPolicy.today(now: started, timeZone: .current)),
				rewrites: try IntervalsRewrites.load(),
				ledger: ledger,
				sendRefused: { write in
					LiveResponseTap.rewriteNextBody(LiveCalendarPlan.withUnknownCategory)
					return await client.write(write)
				},
				dropNextAnswer: LiveResponseTap.dropNextAnswer,
				drain: LiveResponseTap.drain)
			await run.run()
			try run.writeFindings(
				to: try LiveRunFolder(kind: .calendar, startedAt: started), checkingFor: key)
			for failure in run.failures {
				Issue.record(Comment(rawValue: failure))
			}
		}
	}
#endif
