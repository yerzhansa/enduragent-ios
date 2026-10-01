import EnduragentCoach
import Foundation
import Testing

@Suite struct PreVaultStoreSeed {
	@Test func generate() async throws {
		let destination = try #require(
			ProcessInfo.processInfo.environment["UPGRADE_STORE_DESTINATION"])
		let root = URL(filePath: destination, directoryHint: .isDirectory)
		let log = SwiftDataRecordLog(
			deviceId: DeviceID(rawValue: "pre-vault-5de5c782"),
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.syncedStoreFileName)),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.localStoreFileName)))
		let transport = FakeModelTransport()
		transport.script = FirstWeekFixture.script(for: "What did my training look like this week?")
		let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
		FirstWeekFixture.install(on: intervals)
		let coach = makeCoach(
			transport: transport, intervals: intervals, store: log,
			clock: FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana"))
		let state = try await coach.sendAndSettle("What did my training look like this week?")
		#expect(replyText(state) == FirstWeekFixture.weekSummary)
		let claims = try await log.fetch(RecordQuery(scope: .deviceLocal([.turnClaim])))
		#expect(claims.skipped.isEmpty)
		#expect(claims.records.count == 1)
		#expect(claims.records.allSatisfy { $0.account == .unconnected })
	}
}
