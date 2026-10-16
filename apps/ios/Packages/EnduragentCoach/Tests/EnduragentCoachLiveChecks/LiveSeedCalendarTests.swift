import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LiveSeedCalendarTests {
	static let today: CivilDate = "2026-10-14"
	static func render(_ activity: SeedActivity) -> Data { Data(activity.externalID.utf8) }

	@Test func theSeedAddsEachCalendarEntryOnceAndARerunAddsOnlyTheMissingOnes() async throws {
		let calendar = FakeSeedCalendar()
		let account = FakeSeedAccount(calendar: calendar)
		let ledger = try temporarySeedLedger()
		var first = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(), ledger: ledger)

		let outcome = try await first.seed(render: Self.render(_:))

		let seeded = LiveSeedCalendar.entries.map(\.externalID)
		#expect(
			calendar.calls.filter { if case .add = $0 { true } else { false } } == [.add(seeded)])
		#expect(Set(outcome.calendarAdded) == Set(seeded))
		#expect(Set(outcome.calendarListed.compactMap(\.externalId)) == Set(seeded))
		let note = try #require(calendar.events.first { $0.category == "NOTE" })
		#expect(note.name == "")
		#expect(note.startDateLocal == "2026-10-17T00:00:00")
		let race = try #require(calendar.events.first { $0.category == "RACE_A" })
		#expect(race.coachCreated && race.movingTime == 5_400 && race.trainingLoad == 120)
		let athletes = try #require(
			calendar.events.first { $0.name?.contains("Athlete's own") == true })
		#expect(!athletes.coachCreated)
		let past = try #require(calendar.events.first { $0.name?.contains("Past") == true })
		#expect(past.coachCreated && past.startDateLocal == "2026-10-11T00:00:00")
		let k = try #require(
			calendar.events.first { $0.externalId == "enduragent-seed-calendar-K" })
		let t1 = try #require(
			calendar.events.first { $0.externalId == "enduragent-seed-calendar-T1" })
		#expect(k.startDateLocal == t1.startDateLocal && k.movingTime == 2_700)

		for target in ["T2", "T5"] {
			let id = try #require(
				calendar.events.first { $0.externalId == "enduragent-seed-calendar-\(target)" }?.id)
			_ = calendar.write(.delete(id))
		}
		_ = calendar.write(
			.update(
				t1.id,
				try WorkoutPatch.parse(
					.object(["durationSeconds": .number(4_500)]), today: Self.today)))
		var rerun = LiveSeeder(
			account: account, today: Self.today.adding(days: 2), polling: instantPolling(),
			ledger: try LiveSeedLedger(file: ledger.file))

		let again = try await rerun.seed(render: Self.render(_:))

		#expect(
			calendar.calls.filter { if case .add = $0 { true } else { false } }.last
				== .add(["enduragent-seed-calendar-T2", "enduragent-seed-calendar-T5"]))
		#expect(
			again.calendarAdded == ["enduragent-seed-calendar-T2", "enduragent-seed-calendar-T5"])
		#expect(again.calendarKept.count == seeded.count - 2)
		#expect(calendar.events.first { $0.id == t1.id }?.movingTime == 4_500)
		#expect(calendar.events.count == seeded.count)
		#expect(try LiveSeedLedger(file: ledger.file).calendar.count == seeded.count)
	}

	@Test func unseedRemovesOnlyTheCalendarEntriesTheLedgerNames() async throws {
		let foreign = CalendarEvent(
			id: EventID(rawValue: 42), startDateLocal: "2026-10-20T00:00:00", name: "Club ride",
			category: "WORKOUT", externalId: "enduragent-seed-calendar-T1-copy", uid: nil,
			tags: [], coachCreated: false)
		let calendar = FakeSeedCalendar(events: [foreign])
		let account = FakeSeedAccount(calendar: calendar)
		var seeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(),
			ledger: try temporarySeedLedger())
		_ = try await seeder.seed(render: Self.render(_:))
		let moved = try #require(
			calendar.events.first { $0.externalId == "enduragent-seed-calendar-T3" })
		_ = calendar.write(
			.update(
				moved.id,
				try WorkoutPatch.parse(.object(["date": .string("2027-06-01")]), today: Self.today))
		)
		var unseeder = LiveSeeder(
			account: account, today: Self.today, polling: instantPolling(),
			ledger: try LiveSeedLedger(file: seeder.ledger.file))

		let outcome = try await unseeder.unseed(retiringLedgerAs: "ledger-unseeded.tsv")

		#expect(calendar.events == [foreign])
		#expect(
			Set(outcome.calendarRemoved.keys) == Set(LiveSeedCalendar.entries.map(\.externalID)))
		#expect(outcome.calendarRemoved["enduragent-seed-calendar-T3"] == [moved.id])
	}
}
