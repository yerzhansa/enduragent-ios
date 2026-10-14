import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LiveSeederTests {
	static let today: CivilDate = "2026-10-14"
	static func render(_ activity: SeedActivity) -> Data { Data(activity.externalID.utf8) }

	static func ledger(athlete: String?, activities: [String], wellness fields: [String]) throws
		-> LiveSeedLedger
	{
		var ledger = try temporarySeedLedger()
		if let athlete {
			try ledger.record(athlete: athlete)
		}
		try ledger.record(anchor: today)
		for (position, id) in activities.enumerated() {
			try ledger.record(activity: "enduragent-seed-\(id)-\(position)", id: id)
		}
		if !fields.isEmpty {
			try ledger.record(wellness: "2026-10-01", fields: fields)
		}
		return ledger
	}

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
		try ledger.record(athlete: "i1001")
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

	@Test func unseedDeletesOnlyTheLedgerIDsAndClearsOnlyTheValuesTheSeedStillHolds()
		async throws
	{
		let planned = try #require(
			LiveSeedPlan(anchor: Self.today).wellness.first { $0.date == "2026-10-01" })
		let seededHRV = try #require(planned.values["hrv"])
		let ledger = try Self.ledger(
			athlete: "i1001", activities: ["i100", "i101"], wellness: ["hrv", "weight"])
		let account = FakeSeedAccount(
			listed: [
				SeedListing(id: "i100", externalID: "enduragent-seed-threshold", load: 90),
				SeedListing(id: "i101", externalID: "enduragent-seed-base-01", load: 60),
				SeedListing(id: "i555", name: "Commute", load: 20),
			],
			days: [
				"2026-10-01": ["hrv": seededHRV, "weight": 81.5, "restingHR": 47],
				"2026-10-02": ["hrv": 58],
			])
		var seeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: ledger.file))

		let outcome = try await seeder.unseed(retiringLedgerAs: "ledger-unseeded.tsv")

		#expect(outcome.deleted.sorted() == ["i100", "i101"])
		#expect(await account.deleted.sorted() == ["i100", "i101"])
		#expect(await account.listed.map(\.id) == ["i555"])
		#expect(await account.wellnessWrites == [["2026-10-01": ["hrv": nil]]])
		#expect(await account.days["2026-10-01"] == ["weight": 81.5, "restingHR": 47])
		#expect(await account.days["2026-10-02"] == ["hrv": 58])
		#expect(outcome.cleared == ["2026-10-01": ["hrv"]])
		#expect(outcome.changedSinceSeed == ["2026-10-01 weight"])
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

	@Test func unseedFailsAndKeepsItsLedgerWhenTheClearedWellnessReadsBackSet() async throws {
		let planned = try #require(
			LiveSeedPlan(anchor: Self.today).wellness.first { $0.date == "2026-10-01" })
		let ledger = try Self.ledger(
			athlete: "i1001", activities: ["i100"], wellness: SeedWellnessDay.fields)
		let account = FakeSeedAccount(
			listed: [SeedListing(id: "i100", externalID: "enduragent-seed-threshold", load: 90)],
			days: ["2026-10-01": planned.values], nullClears: false)
		var seeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: ledger.file))

		let stop = await #expect(throws: LiveCheckStop.self) {
			_ = try await seeder.unseed(retiringLedgerAs: "ledger-unseeded.tsv")
		}

		#expect(
			stop?.description
				== "The account still holds seeded wellness after clearing it: 2026-10-01 hrv, 2026-10-01 restingHR, 2026-10-01 sleepSecs, 2026-10-01 weight"
		)
		#expect(await account.wellnessWrites.count == 1)
		#expect(FileManager.default.fileExists(atPath: ledger.file.path))
	}

	@Test func theSeedRecordsItsAthleteAndAnotherAthletesKeyChangesNothing() async throws {
		let owner = FakeSeedAccount(athlete: "i1001")
		var seeder = LiveSeeder(
			account: owner, today: Self.today, polling: instantPolling(),
			ledger: try temporarySeedLedger())
		_ = try await seeder.seed(render: Self.render(_:))
		let file = seeder.ledger.file
		#expect(try LiveSeedLedger(file: file).athlete == "i1001")

		let other = FakeSeedAccount(
			athlete: "i2002", listed: await owner.listed, days: await owner.days)
		var unseeder = LiveSeeder(
			account: other, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: file))
		let unseedStop = await #expect(throws: LiveCheckStop.self) {
			_ = try await unseeder.unseed(retiringLedgerAs: "ledger-unseeded.tsv")
		}
		var reseeder = LiveSeeder(
			account: other, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: file))
		let seedStop = await #expect(throws: LiveCheckStop.self) {
			_ = try await reseeder.seed(render: Self.render(_:))
		}

		let refusal =
			"Nothing was changed: the seed ledger belongs to athlete i1001, but the key belongs to athlete i2002."
		#expect(unseedStop?.description == refusal)
		#expect(seedStop?.description == refusal)
		#expect(await other.deleted.isEmpty)
		#expect(await other.uploads.isEmpty)
		#expect(await other.ratings.isEmpty)
		#expect(await other.wellnessWrites.isEmpty)
		#expect(FileManager.default.fileExists(atPath: file.path))
	}

	@Test func aLedgerWithoutAnAthleteIsTrustedOnlyWhenTheAccountListsEveryActivityItRecords()
		async throws
	{
		let planned = try #require(
			LiveSeedPlan(anchor: Self.today).wellness.first { $0.date == "2026-10-01" })
		let seeded = [
			SeedListing(id: "i100", externalID: "enduragent-seed-threshold", load: 90),
			SeedListing(id: "i101", externalID: "enduragent-seed-base-01", load: 60),
		]
		let legacy = try Self.ledger(
			athlete: nil, activities: ["i100", "i101"], wellness: SeedWellnessDay.fields)
		let stranger = FakeSeedAccount(
			athlete: "i2002",
			listed: [seeded[0], SeedListing(id: "i555", name: "Commute", load: 20)],
			days: ["2026-10-01": planned.values])
		var refused = LiveSeeder(
			account: stranger, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: legacy.file))

		let stop = await #expect(throws: LiveCheckStop.self) {
			_ = try await refused.unseed(retiringLedgerAs: "ledger-unseeded.tsv")
		}

		#expect(
			stop?.description
				== "Nothing was changed: the seed ledger names no athlete, and athlete i2002 does not list its activities i101"
		)
		#expect(await stranger.deleted.isEmpty)
		#expect(await stranger.wellnessWrites.isEmpty)
		#expect(try LiveSeedLedger(file: legacy.file).athlete == nil)

		let owner = FakeSeedAccount(
			athlete: "i1001", listed: seeded, days: ["2026-10-01": planned.values])
		var accepted = LiveSeeder(
			account: owner, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: legacy.file))
		let outcome = try await accepted.unseed(retiringLedgerAs: "ledger-unseeded.tsv")

		#expect(outcome.deleted.sorted() == ["i100", "i101"])
		#expect(outcome.cleared == ["2026-10-01": SeedWellnessDay.fields])
		#expect(await owner.days["2026-10-01"] == [:])
		let retired = legacy.file.deletingLastPathComponent().appending(path: "ledger-unseeded.tsv")
		#expect(try LiveSeedLedger(file: retired).athlete == "i1001")

		let wellnessOnly = try Self.ledger(athlete: nil, activities: [], wellness: ["hrv"])
		let unprovable = FakeSeedAccount(days: ["2026-10-01": planned.values])
		var orphan = LiveSeeder(
			account: unprovable, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: wellnessOnly.file))
		let orphanStop = await #expect(throws: LiveCheckStop.self) {
			_ = try await orphan.unseed(retiringLedgerAs: "ledger-unseeded.tsv")
		}
		#expect(orphanStop?.description.contains("names no athlete and no activity") == true)
		#expect(await unprovable.wellnessWrites.isEmpty)
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
