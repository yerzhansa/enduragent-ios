import Foundation
import Testing

@testable import EnduragentCoach

extension LiveSeederTests {
	@Test func aLedgerIDTheAccountNoLongerHasIsUploadedAgainWithoutWaiting() async throws {
		var ledger = try temporarySeedLedger()
		try ledger.record(athlete: "i1001")
		try ledger.record(anchor: Self.today)
		try ledger.record(activity: "enduragent-seed-threshold", id: "i100")
		let account = FakeSeedAccount()
		let slept = SleepCount()
		var seeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(slept: slept),
			ledger: try LiveSeedLedger(file: ledger.file))

		let outcome = try await seeder.seed(render: Self.render(_:))

		let reseeded = try #require(seeder.ledger.activities["enduragent-seed-threshold"])
		#expect(await account.lookups == ["i100"])
		#expect(await account.uploads.contains("enduragent-seed-threshold"))
		#expect(outcome.uploaded.contains("enduragent-seed-threshold"))
		#expect(outcome.kept.isEmpty)
		#expect(reseeded != "i100")
		#expect(await account.listed.contains { $0.id == reseeded })
		#expect(
			try LiveSeedLedger(file: ledger.file).activities["enduragent-seed-threshold"]
				== reseeded)
		#expect(await slept.count == 0)
	}
}
