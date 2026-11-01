import EnduragentCoach
import Foundation
import Testing

@Suite struct V1UpgradeStoreSeed {
	@Test func generate() async throws {
		let destination = try #require(
			ProcessInfo.processInfo.environment["V1_UPGRADE_DESTINATION"])
		let root = URL(filePath: destination, directoryHint: .isDirectory)
		try await seed(
			root.appending(path: "history"),
			turns: [
				("v1-first", "What did my training look like this week?", "1998-06-15T08:00:00Z"),
				(
					"v1-second", "Remember that I ride with a group on Saturdays",
					"1998-06-16T08:00:00Z"
				),
			])
		try await seed(
			root.appending(path: "review"),
			turns: [
				(
					"main",
					"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks",
					"1998-06-15T08:00:00Z"
				)
			])
	}

	private func seed(_ root: URL, turns: [(String, String, String)]) async throws {
		let device = DeviceID(rawValue: "v1-upgrade-fixture")
		let log = SwiftDataRecordLog(
			deviceId: device,
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.syncedStoreFileName)),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.localStoreFileName)))
		for (chat, question, instant) in turns {
			let transport = FakeModelTransport()
			transport.script = FirstWeekFixture.script(for: question)
			let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
			FirstWeekFixture.install(on: intervals)
			let coach = Coach(
				sport: .cycling, transport: transport, intervals: intervals, store: log,
				clock: FixedClock(now: instant, timeZone: "Europe/Ljubljana"),
				language: LanguagePreference(ui: .en, coachReply: nil))
			let id = try #require(ChatID(rawValue: chat))
			for try await _ in coach.send(question, chatId: id) {}
			#expect(await coach.history(chatId: id).count == 2)
		}
		let synced = try await log.fetch(RecordQuery(kinds: [.userMessage, .assistantMessage]))
		#expect(synced.count == turns.count * 2)
		let pending = try await log.fetch(
			RecordQuery(kinds: [.pendingProposal], deviceLocalOnly: true))
		#expect(pending.count == (root.lastPathComponent == "review" ? 1 : 0))
	}
}
