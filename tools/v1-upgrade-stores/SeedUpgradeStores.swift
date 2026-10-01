import EnduragentCoach
import Foundation
import Testing

@Suite struct SeedUpgradeStores {
	@Test func generate() async throws {
		let output = try #require(ProcessInfo.processInfo.environment["UPGRADE_STORE_OUTPUT"])
		for scenario in ["history", "review"] {
			let directory = URL(filePath: output).appending(path: scenario)
			let store = SwiftDataRecordLog(
				deviceId: DeviceID(rawValue: "v1-upgrade-proof"),
				synced: try .withoutCloudKit(
					storeURL: directory.appending(path: "synced-records.store")),
				local: try .withoutCloudKit(
					storeURL: directory.appending(path: "local-records.store")))
			let transport = FakeModelTransport()
			let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
			FirstWeekFixture.install(on: intervals)
			let clock = FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana")
			let coach = Coach(
				sport: .cycling, transport: transport, intervals: intervals, store: store,
				clock: clock,
				language: LanguagePreference(ui: .en, coachReply: nil))
			let turns: [(ChatID, String)] =
				scenario == "history"
				? [
					("v1-week", "What did my training look like this week?"),
					("v1-memory", "Remember that I ride with a group on Saturdays"),
				]
				: [
					(
						.main,
						"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
					)
				]
			for (chat, question) in turns {
				transport.script = FirstWeekFixture.script(for: question)
				for try await _ in coach.send(question, chatId: chat) {}
				clock.advance(by: 60)
				#expect(await coach.history(chatId: chat).count == 2)
			}
			let pending = try await store.fetch(RecordQuery(kinds: [.pendingProposal]))
			#expect(pending.count == (scenario == "review" ? 1 : 0))
			#expect(try await store.fetch(RecordQuery(kinds: [.proposalCleared])).isEmpty)
		}
	}
}
