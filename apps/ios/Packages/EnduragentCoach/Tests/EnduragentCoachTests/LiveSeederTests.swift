import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LiveSeederTests {
	static let today: CivilDate = "2026-10-14"
	static func render(_ activity: SeedActivity) -> Data { Data(activity.externalID.utf8) }

	@Test func theGuardRefusesAnAccountWithTrainingTheSeedDidNotWrite() async throws {
		let real = SeedListing(
			id: "i4711", name: "Morning Ride", externalID: "garmin-123",
			start: "2026-06-01T07:00:00",
			load: 80)
		let account = FakeSeedAccount(listed: [real])
		var seeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(),
			ledger: try temporarySeedLedger())

		let stop = await #expect(throws: LiveCheckStop.self) {
			_ = try await seeder.seed(render: Self.render(_:))
		}
		#expect(stop?.description.contains(#"i4711 "Morning Ride" 2026-06-01T07:00:00"#) == true)
		#expect(await account.uploads.isEmpty)
		#expect(await account.wellnessWrites.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: seeder.ledger.file.path))

		let weighed = FakeSeedAccount(days: ["2026-09-20": ["weight": 81.5]])
		var wellnessSeeder = LiveSeeder(
			account: weighed, today: Self.today, polling: instantPolling(),
			ledger: try temporarySeedLedger())
		let wellnessStop = await #expect(throws: LiveCheckStop.self) {
			_ = try await wellnessSeeder.seed(render: Self.render(_:))
		}
		#expect(wellnessStop?.description.contains("2026-09-20") == true)
		#expect(await weighed.uploads.isEmpty)
		#expect(await weighed.wellnessWrites.isEmpty)
	}

	@Test func aRerunSkipsWhatTheLedgerRecordsOrTheAccountListsAndAddsOnlyTheRest() async throws {
		let plan = LiveSeedPlan(anchor: Self.today)
		var ledger = try temporarySeedLedger()
		try ledger.record(anchor: Self.today)
		try ledger.record(activity: "enduragent-seed-threshold", id: "i100")
		let account = FakeSeedAccount(
			listed: [SeedListing(id: "i101", externalID: "enduragent-seed-base-01", load: 60)],
			listedFromSecondRead: [
				SeedListing(id: "i100", externalID: "enduragent-seed-threshold", load: 90)
			])
		var first = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: ledger.file))

		let outcome = try await first.seed(render: Self.render(_:))

		let uploads = await account.uploads
		#expect(uploads.count == plan.activities.count - 2)
		#expect(!uploads.contains("enduragent-seed-threshold"))
		#expect(!uploads.contains("enduragent-seed-base-01"))
		#expect(Set(outcome.kept) == ["enduragent-seed-threshold", "enduragent-seed-base-01"])
		#expect(first.ledger.activities["enduragent-seed-base-01"] == "i101")
		#expect(await account.ratings.count == 5)
		#expect(outcome.wellnessWritten.count == LiveSeedPlan.days)

		var rerun = LiveSeeder(
			account: account, today: Self.today.adding(days: 3), polling: instantPolling(),
			ledger: try LiveSeedLedger(file: ledger.file))
		let again = try await rerun.seed(render: Self.render(_:))

		#expect(await account.uploads.count == uploads.count)
		#expect(await account.ratings.count == 5)
		#expect(await account.wellnessWrites.count == 1)
		#expect(again.uploaded.isEmpty && again.rated.isEmpty && again.wellnessWritten.isEmpty)
		#expect(rerun.ledger.anchor == Self.today)
		#expect(rerun.ledger.activities.count == plan.activities.count)
		#expect(rerun.ledger.wellness.count == LiveSeedPlan.days)
	}

	@Test func unseedDeletesOnlyTheLedgerIDsAndClearsOnlyTheFieldsItWrote() async throws {
		var ledger = try temporarySeedLedger()
		try ledger.record(anchor: Self.today)
		try ledger.record(activity: "enduragent-seed-threshold", id: "i100")
		try ledger.record(activity: "enduragent-seed-base-01", id: "i101")
		try ledger.record(wellness: "2026-10-01", fields: ["hrv", "weight"])
		let account = FakeSeedAccount(
			listed: [
				SeedListing(id: "i100", externalID: "enduragent-seed-threshold", load: 90),
				SeedListing(id: "i101", externalID: "enduragent-seed-base-01", load: 60),
				SeedListing(id: "i555", name: "Commute", load: 20),
			],
			days: [
				"2026-10-01": ["hrv": 61, "weight": 72.1, "restingHR": 47],
				"2026-10-02": ["hrv": 58],
			])
		var seeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: ledger.file))

		let deleted = try await seeder.unseed(retiringLedgerAs: "ledger-unseeded.tsv")

		#expect(deleted.sorted() == ["i100", "i101"])
		#expect(await account.deleted.sorted() == ["i100", "i101"])
		#expect(await account.listed.map(\.id) == ["i555"])
		#expect(await account.days["2026-10-01"] == ["restingHR": 47])
		#expect(await account.days["2026-10-02"] == ["hrv": 58])
		#expect(!FileManager.default.fileExists(atPath: ledger.file.path))
		#expect(
			FileManager.default.fileExists(
				atPath: ledger.file.deletingLastPathComponent().appending(
					path: "ledger-unseeded.tsv"
				).path
			))

		let leftover = FakeSeedAccount(listed: [
			SeedListing(
				id: "i300", name: "[synthetic] Endurance", externalID: "enduragent-seed-base-02")
		])
		var partial = LiveSeeder(
			account: leftover, today: Self.today, polling: instantPolling(),
			ledger: try temporarySeedLedger())
		let stop = await #expect(throws: LiveCheckStop.self) {
			_ = try await partial.unseed(retiringLedgerAs: "ledger-unseeded.tsv")
		}
		#expect(stop?.description.contains("i300") == true)
		#expect(await leftover.deleted.isEmpty)
	}

	@Test func aSeedThatNeverProcessesFailsWithItsIDsAfterABoundedWait() async throws {
		let account = FakeSeedAccount(processes: false)
		let slept = SleepCount()
		var seeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(attempts: 4, slept: slept),
			ledger: try temporarySeedLedger())

		let stop = await #expect(throws: LiveCheckStop.self) {
			_ = try await seeder.seed(render: Self.render(_:))
		}

		#expect(await slept.count == 3)
		let ids = await account.listed.map(\.id)
		#expect(ids.count == LiveSeedPlan(anchor: Self.today).activities.count)
		#expect(ids.allSatisfy { stop?.description.contains($0) == true })
		#expect(await account.ratings.isEmpty)
	}
}
