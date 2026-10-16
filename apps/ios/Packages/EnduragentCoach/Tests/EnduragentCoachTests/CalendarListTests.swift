import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CalendarListTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
	let week = #"{"oldest":"1998-06-14","newest":"1998-06-20"}"#

	@Test func listHoldsTheWorkoutsAndRacesOfTheRangeWithTheirDurationAndLoad() async throws {
		intervals.events = mixedWeek
		let rows = try await list(week)
		#expect(
			rows
				== (try JSONValue.parse(
					"""
					[
					{"id":1,"startDateLocal":"1998-06-14T00:00:00","name":"Endurance","category":"WORKOUT","tags":["cycling-coach"],"coachCreated":true,"durationSeconds":3600,"load":52},
					{"id":2,"startDateLocal":"1998-06-15T00:00:00","name":"Local race","category":"RACE_A","tags":[],"coachCreated":false,"durationSeconds":7200,"load":140},
					{"id":3,"startDateLocal":"1998-06-16T00:00:00","name":"Club race","category":"RACE_B","tags":["cycling-coach"],"coachCreated":true,"durationSeconds":5400,"load":95},
					{"id":4,"startDateLocal":"1998-06-17T00:00:00","name":"Hill climb","category":"RACE_C","tags":[],"coachCreated":false,"durationSeconds":1800,"load":40}
					]
					"""
				)))
		#expect(intervals.calls == [.events(oldest: "1998-06-14", newest: "1998-06-20")])
	}

	@Test func coachCreatedOnlyListsTheCoachRowsAndACoachRaceStaysARace() async throws {
		intervals.events = mixedWeek
		let rows = try await list(
			#"{"oldest":"1998-06-14","newest":"1998-06-20","coachCreatedOnly":true}"#)
		#expect(rows.arrayValue?.map(\.objectFields["id"]) == [.number(1), .number(3)])
		let race = try #require(rows.arrayValue?.last?.objectFields)
		#expect(race["category"] == .string("RACE_B"))
		#expect(race["coachCreated"] == .bool(true))
	}

	@Test func anUnknownDurationOrLoadHasNoKeyAndAZeroDurationIsListed() async throws {
		intervals.events = [
			workout(1, on: "1998-06-14", movingTime: nil, trainingLoad: 30),
			workout(2, on: "1998-06-15", movingTime: 2700, trainingLoad: nil),
			workout(3, on: "1998-06-16", movingTime: 0, trainingLoad: 0),
		]
		let rows = try #require(try await list(week).arrayValue).map(\.objectFields)
		#expect(rows[0]["durationSeconds"] == nil)
		#expect(rows[0]["load"] == .number(30))
		#expect(rows[1]["durationSeconds"] == .number(2700))
		#expect(rows[1]["load"] == nil)
		#expect(rows[2]["durationSeconds"] == .number(0))
		#expect(rows[2]["load"] == .number(0))
	}

	@Test func anUnnamedEntryListsWithoutANameBesideTheRestOfTheRange() async throws {
		var unnamed = workout(1, on: "1998-06-14", movingTime: 3600, trainingLoad: 52)
		unnamed.name = nil
		intervals.events = [
			unnamed, workout(2, on: "1998-06-15", movingTime: 2700, trainingLoad: 40),
		]
		let rows = try #require(try await list(week).arrayValue).map(\.objectFields)
		#expect(rows.count == 2)
		#expect(rows[0]["name"] == nil)
		#expect(rows[0]["durationSeconds"] == .number(3600))
		#expect(rows[1]["name"] == .string("Ride 2"))
	}

	@Test(arguments: [
		(
			#"{"oldest":"1998-02-30","newest":"1998-06-20"}"#,
			#"{"error":"invalid_date","details":"1998-02-30 is not a real calendar date. Use YYYY-MM-DD."}"#
		),
		(
			#"{"oldest":"1998-06-14","newest":"20-06-1998"}"#,
			#"{"error":"invalid_date","details":"20-06-1998 is not a real calendar date. Use YYYY-MM-DD."}"#
		),
	])
	func aMalformedDateIsRefusedBeforeAnyRead(arguments: String, refusal: String) async throws {
		intervals.events = mixedWeek
		#expect(try await list(arguments) == (try JSONValue.parse(refusal)))
		#expect(intervals.calls.isEmpty)
	}

	@Test func aRangeOfExactly366DaysIsRead() async throws {
		intervals.events = [
			workout(1, on: "1998-12-31", movingTime: 3600, trainingLoad: 50),
			workout(2, on: "1999-01-01", movingTime: 3600, trainingLoad: 50),
			workout(3, on: "2000-01-01", movingTime: 3600, trainingLoad: 50),
			workout(4, on: "2000-01-02", movingTime: 3600, trainingLoad: 50),
		]
		let rows = try await list(#"{"oldest":"1999-01-01","newest":"2000-01-01"}"#)
		#expect(intervals.calls == [.events(oldest: "1999-01-01", newest: "2000-01-01")])
		#expect(rows.arrayValue?.map(\.objectFields["id"]) == [.number(2), .number(3)])
	}

	@Test func anOmittedNewestReadsUpToThePhonesDay() async throws {
		let auckland = FixedClock(now: "1998-09-08T00:30:00+12:00", timeZone: "Pacific/Auckland")
		_ = try await list(#"{"oldest":"1998-09-01"}"#, clock: auckland)
		#expect(intervals.calls == [.events(oldest: "1998-09-01", newest: "1998-09-08")])
	}

	@Test func theDescriptionNamesWorkoutsAndRacesAndNoWorkoutOnlyFilter() throws {
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let schema = try #require(
			makeToolOffer(
				training: connectedTraining(intervals),
				ledger: Ledger(
					log: InMemoryRecordLog(), clock: clock,
					diagnostics: DiagnosticsLog(clock: clock)),
				clock: clock
			).schemas.first { $0.name == .intervalsListEvents })
		#expect(!schema.description.contains("Filters to WORKOUT category only"))
		#expect(schema.description.contains("WORKOUT, RACE_A, RACE_B and RACE_C"))
		#expect(schema.description.contains("never changeable"))
		#expect(schema.description.contains("coachCreatedOnly"))
	}

	private var mixedWeek: [CalendarEvent] {
		[
			CalendarEvent(
				id: EventID(rawValue: 1), startDateLocal: "1998-06-14T00:00:00", name: "Endurance",
				category: "WORKOUT", externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag],
				coachCreated: true, movingTime: 3600, trainingLoad: 52),
			CalendarEvent(
				id: EventID(rawValue: 2), startDateLocal: "1998-06-15T00:00:00", name: "Local race",
				category: "RACE_A", externalId: nil, uid: nil, tags: [], coachCreated: false,
				movingTime: 7200, trainingLoad: 140),
			CalendarEvent(
				id: EventID(rawValue: 3), startDateLocal: "1998-06-16T00:00:00", name: "Club race",
				category: "RACE_B", externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag],
				coachCreated: true, movingTime: 5400, trainingLoad: 95),
			CalendarEvent(
				id: EventID(rawValue: 4), startDateLocal: "1998-06-17T00:00:00", name: "Hill climb",
				category: "RACE_C", externalId: nil, uid: nil, tags: [], coachCreated: false,
				movingTime: 1800, trainingLoad: 40),
			CalendarEvent(
				id: EventID(rawValue: 5), startDateLocal: "1998-06-18T00:00:00", name: "Rest note",
				category: "NOTE", externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag],
				coachCreated: true, movingTime: 0, trainingLoad: 0),
			CalendarEvent(
				id: EventID(rawValue: 6), startDateLocal: "1998-06-19T00:00:00", name: "Trip",
				category: "HOLIDAY", externalId: nil, uid: nil, tags: [], coachCreated: false),
		]
	}

	private func workout(_ id: Int, on date: String, movingTime: Int?, trainingLoad: Int?)
		-> CalendarEvent
	{
		CalendarEvent(
			id: EventID(rawValue: id), startDateLocal: "\(date)T00:00:00", name: "Ride \(id)",
			category: "WORKOUT", externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag],
			coachCreated: true, movingTime: movingTime, trainingLoad: trainingLoad)
	}

	private func list(
		_ arguments: String,
		clock: FixedClock = FixedClock(
			now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	) async throws -> JSONValue {
		let outcome = try await makeOfferedTools(
			intervals: intervals,
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		).execute(
			name: .intervalsListEvents, arguments: try JSONValue.parse(arguments),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		).outcome
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "no_result", details: "\(outcome)")
		}
		return try #require(json.objectFields["data"])
	}
}
