import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct LiveCalendarPlanTests {
	static let today: CivilDate = "2026-10-16"
	static let key = "icu-live-calendar-test-key"

	static func seeded(
		stores: @escaping @Sendable (Set<String>, CalendarEvent) -> CalendarEvent = { $1 }
	) -> FakeSeedCalendar {
		let calendar = FakeSeedCalendar(stores: stores)
		_ = calendar.add(LiveSeedCalendar.entries.map { $0.requestBody(seededOn: today) })
		return calendar
	}

	static func run(
		athlete: String = "i1001", ledgerAthlete: String? = "i1001",
		calendar: FakeSeedCalendar = seeded(), rewrites: IntervalsRewrites? = nil,
		refused: IntervalsWriteAnswer = .httpStatus(400),
		drain: @escaping @Sendable () -> [TappedResponse] = { [] }
	) throws -> LiveCalendarRun {
		var ledger = try temporarySeedLedger()
		if let ledgerAthlete {
			try ledger.record(athlete: ledgerAthlete)
		}
		return LiveCalendarRun(
			account: FakeSeedAccount(athlete: athlete, calendar: calendar),
			plan: try LiveCalendarPlan(today: today),
			rewrites: try rewrites ?? IntervalsRewrites.load(),
			ledger: ledger,
			sendRefused: { _ in refused },
			drain: drain)
	}

	@Test func thePlanAddsARepeatRideAStrengthSessionAndOneEditPerFieldAfterToday() throws {
		let plan = try LiveCalendarPlan(today: Self.today)

		#expect(plan.adds.allSatisfy { $0.payload.date > Self.today })
		#expect(Set(plan.adds.map(\.externalID)).count == plan.adds.count)
		#expect(plan.adds.allSatisfy { $0.externalID == "cycling-coach:\($0.identity.uid)" })
		#expect(plan.ride.payload.movingTime == 900)
		#expect(plan.ride.payload.description.contains("- 1m 50%\n\n- 2m 65%"))
		#expect(plan.ride.payload.trainingLoad == 21)
		#expect(plan.strength.payload.type == .weightTraining)
		#expect(plan.strength.payload.movingTime == 2_250)
		#expect(plan.strength.payload.description.hasPrefix("Moderate, RPE 6\n\n3 x 10"))
		#expect(
			plan.edits.map(\.field) == [
				"date", "name", "trainingLoad", "durationSeconds", "description", "structure",
			])
		#expect(
			plan.edits.map { Set($0.patch.requestBody.objectFields.keys) } == [
				["start_date_local"], ["name"], ["icu_training_load"], ["moving_time"],
				["description"], ["description", "moving_time"],
			])
		#expect(plan.movedNear.destination == plan.movedNear.add.payload.date.adding(days: 30))
		#expect(try plan.movedNear.staysInWindow)
		#expect(try !plan.movedFar.staysInWindow)
		let window = try LiveSeedCalendar.window(around: Self.today)
		#expect(IntervalsPolicy.inclusiveDayCount(from: window.oldest, to: window.newest) == 366)
		#expect(window.oldest == Self.today.adding(days: -183))
	}

	@Test func theRefusedAddDiffersFromItsBodyOnlyInItsCategory() throws {
		let plan = try LiveCalendarPlan(today: Self.today)
		let body = Data(JSONValue.array([plan.refused.body]).canonicalDigestInput().utf8)

		let sent = try JSONValue.parse(
			String(decoding: LiveCalendarPlan.withUnknownCategory(body), as: UTF8.self))

		var expected = plan.refused.body.objectFields
		expected["category"] = .string(LiveCalendarPlan.unknownCategory)
		#expect(sent == .array([.object(expected)]))
	}

	@Test func aRunAgainstACalendarThatKeepsWhatItIsSentPassesAndRemovesEveryAdd() async throws {
		let calendar = Self.seeded()
		let seededIDs = Set(calendar.events.map(\.id))
		var run = try Self.run(calendar: calendar)

		await run.run()

		#expect(run.failures == [])
		#expect(Set(calendar.events.map(\.id)) == seededIDs)
		#expect(run.ledger.calendar.isEmpty)
		let reread = try LiveSeedLedger(file: run.ledger.file)
		#expect(reread.calendar.isEmpty)
		let adds = calendar.writes.filter {
			if case .create = $0 { return true }
			return false
		}
		#expect(adds.count == 8)
	}

	@Test func aResendThatAddsASecondEventOrASavedRefusedAddFailsTheRun() async throws {
		let calendar = FakeSeedCalendar(upsertsByExternalID: false)
		_ = calendar.add(LiveSeedCalendar.entries.map { $0.requestBody(seededOn: Self.today) })
		var run = try Self.run(calendar: calendar, refused: .saved(nil))

		await run.run()

		let failures = Set(run.failures)
		#expect(failures.contains { $0.hasPrefix("resend ride: the second send answered event") })
		#expect(
			failures.contains(
				"resend ride: 2 events carry ride's external_id, not event 7010 alone"))
		#expect(failures.contains { $0.hasPrefix("resend moved-30: the resend answered event") })
		#expect(failures.contains { $0.hasPrefix("resend moved-200: the resend answered event") })
		#expect(failures.contains("refused refused: an add with an unknown category was saved"))
		#expect(calendar.events.count == LiveSeedCalendar.entries.count)
	}

	@Test func aKeyOfAnotherAthleteStopsTheCheckBeforeAnyRequestOrLedgerRow() async throws {
		for (athlete, ledgerAthlete) in [("i2002", "i1001"), ("i1001", nil)] {
			let calendar = Self.seeded()
			let before = calendar.calls.count
			var run = try Self.run(
				athlete: athlete, ledgerAthlete: ledgerAthlete, calendar: calendar)
			let rows = try Self.rows(of: run.ledger)

			await run.run()

			#expect(run.failures.count == 1)
			#expect(run.failures.first?.hasPrefix("athlete guard: Nothing was written") == true)
			#expect(calendar.calls.count == before)
			#expect(try Self.rows(of: run.ledger) == rows)
		}
	}

	@Test func aRunFolderFileThatHoldsTheKeyFailsTheRun() async throws {
		let echoed = TappedResponse(
			method: "GET", path: "/api/v1/athlete/0", query: nil, status: 200,
			body: Data(#"{"id":"i1001","note":"\#(Self.key)"}"#.utf8))
		let leaking = LeakingDrain(response: echoed)
		var run = try Self.run(drain: { leaking.next() })
		await run.run()
		let folder = try LiveRunFolder(
			logs: TestTemporaryFolders.make(), kind: .calendar, startedAt: Date())

		try run.writeFindings(to: folder, checkingFor: Self.key)

		#expect(
			run.failures.contains { $0.hasSuffix("the saved file holds the intervals.icu key") })
		#expect(try folder.files(containing: Self.key).count == 1)

		var clean = try Self.run()
		await clean.run()
		try clean.writeFindings(
			to: try LiveRunFolder(
				logs: TestTemporaryFolders.make(), kind: .calendar, startedAt: Date()),
			checkingFor: Self.key)
		#expect(clean.failures == [])
	}

	@Test func aSaveThatChangesAFieldFailsUnlessTheRewritesFileExplainsIt() async throws {
		let estimating: @Sendable (Set<String>, CalendarEvent) -> CalendarEvent = { sent, event in
			guard sent.contains("description"), event.description?.contains("\n- ") == true
			else { return event }
			var stored = event
			stored.trainingLoad = 7
			stored.workoutDocument = .object([
				"steps": .array([.object([:])]),
				"duration": .number(Double(event.movingTime ?? 0)),
			])
			return stored
		}
		var listed = try Self.run(calendar: Self.seeded(stores: estimating))
		await listed.run()
		#expect(listed.failures == [])

		var folded = try Self.run(
			calendar: Self.seeded { sent, event in
				guard sent.contains("description"), event.description?.contains("\n- ") == true
				else { return event }
				var stored = event
				stored.workoutDocument = .object([
					"steps": .array([.object(["reps": .number(3), "duration": .number(900)])]),
					"duration": .number(1_140),
				])
				return stored
			})
		await folded.run()
		#expect(
			folded.failures.contains(
				"add ride: intervals.icu parsed 1140 seconds of steps, not the reviewed 900"))

		var unlisted = try Self.run(
			calendar: Self.seeded(stores: estimating), rewrites: IntervalsRewrites(rewrites: []))
		await unlisted.run()
		#expect(
			unlisted.failures.contains {
				$0
					== "add ride: ride: icu_training_load sent 21, stored 7, a rewrite intervals-rewrites.json does not list"
			})

		var renamed = try Self.run(
			calendar: Self.seeded { _, event in
				var stored = event
				stored.name = event.name?.uppercased()
				return stored
			})
		await renamed.run()
		#expect(
			renamed.failures.contains {
				$0.hasPrefix("add ride: ride: name sent")
					&& $0.hasSuffix("a rewrite intervals-rewrites.json does not list")
			})
	}

	private static func rows(of ledger: LiveSeedLedger) throws -> String {
		guard FileManager.default.fileExists(atPath: ledger.file.path) else { return "" }
		return try String(contentsOf: ledger.file, encoding: .utf8)
	}
}

final class LeakingDrain: Sendable {
	private let response: TappedResponse
	private let given = Mutex(false)

	init(response: TappedResponse) {
		self.response = response
	}

	func next() -> [TappedResponse] {
		given.withLock { given in
			defer { given = true }
			return given ? [] : [response]
		}
	}
}
