import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct ReadToolsTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func calculateZonesMatchesTypeScriptBytes() async throws {
		let expected = try JSONValue.parse(
			try #require(String(data: try fixtureData("zones-ts"), encoding: .utf8)))
		var tables: [String: JSONValue] = [:]
		let tools = runtime()
		for ftp in [200, 250, 280, 400] {
			let outcome = try await tools.execute(
				name: .calculateZones,
				arguments: .object(["ftpWatts": .number(Double(ftp))]),
				chatId: .main,
				scope: turnScope()
			).outcome
			guard case .result(let json) = outcome else {
				Issue.record("expected zone rows")
				return
			}
			tables[String(ftp)] = try #require(json.objectFields["data"])
		}
		let actual = JSONValue.object(tables)
		#expect(
			Array(actual.canonicalDigestInput().utf8) == Array(expected.canonicalDigestInput().utf8)
		)
	}

	@Test func fetchActivitiesDaysSevenRecordsCall() async throws {
		intervals.activities = [
			.ride(name: "Sunday long ride", date: "1998-06-07", durationS: 7200, trainingLoad: 120),
			.ride(name: "Too old", date: "1998-05-01", durationS: 1800, trainingLoad: 40),
		]
		let outcome = try await runtime().execute(
			name: .intervalsFetchActivities,
			arguments: try JSONValue.parse(#"{"days":7}"#),
			chatId: .main,
			scope: turnScope()
		).outcome
		#expect(intervals.calls == [.activities(days: 7)])
		guard case .result(let json) = outcome, let rows = unwrapData(json).arrayValue else {
			Issue.record("expected activities")
			return
		}
		#expect(rows.map { $0.objectFields["name"]?.stringValue } == ["Sunday long ride"])
	}

	@Test func omittedNewestUsesAthleteTimeZoneToday() async throws {
		_ = try await runtime().execute(
			name: .intervalsFetchWellness,
			arguments: try JSONValue.parse(#"{"oldest":"1998-06-07"}"#),
			chatId: .main,
			scope: turnScope()
		).outcome
		#expect(intervals.calls == [.wellness(oldest: "1998-06-07", newest: "1998-06-13")])
	}

	@Test func wellnessToolOmitsCtlAtl() async throws {
		intervals.wellness = [
			WellnessDay(
				date: "1998-06-13", fitness: 55.2, fatigue: 42.1, form: 55.2 - 42.1)
		]
		let outcome = try await runtime().execute(
			name: .intervalsFetchWellness,
			arguments: try JSONValue.parse(#"{"oldest":"1998-06-13","newest":"1998-06-13"}"#),
			chatId: .main,
			scope: turnScope()
		).outcome
		guard case .result(let json) = outcome else {
			Issue.record("expected wellness")
			return
		}
		let encoded = canonicalJSON(unwrapData(json))
		#expect(!encoded.contains("\"ctl\""))
		#expect(!encoded.contains("\"atl\""))
		#expect(encoded.contains("\"fitness\""))
		#expect(encoded.contains("\"Fatigue\"") == false)
		#expect(unwrapData(json).arrayValue?.first?.objectFields["fatigue"]?.numberValue == 42.1)
		#expect(
			unwrapData(json).arrayValue?.first?.objectFields["form"]?.numberValue == 55.2 - 42.1)
	}

	@Test func fetchAthleteAndActivityAndStreamsAndEvents() async throws {
		let activityID = try #require(ActivityID(rawValue: "i1234567"))
		intervals.activity = try JSONValue.parse(#"{"id":"i1234567","name":"Sunday long ride"}"#)
		intervals.streams = try JSONValue.parse(
			try #require(String(data: try fixtureData("streams-ts"), encoding: .utf8)))
		intervals.events = [
			CalendarEvent(
				id: EventID(rawValue: 42),
				startDateLocal: "1998-06-14T00:00:00",
				name: "Endurance",
				category: "WORKOUT",
				externalId: "cycling-coach:1998-06-14:endurance",
				uid: nil,
				tags: ["cycling-coach"],
				coachCreated: true
			),
			CalendarEvent(
				id: EventID(rawValue: 43),
				startDateLocal: "1998-06-20T00:00:00",
				name: "Local race",
				category: "RACE_A",
				externalId: nil,
				uid: nil,
				tags: [],
				coachCreated: false
			),
		]
		let tools = runtime()
		let athlete = try await tools.execute(
			name: .intervalsFetchAthlete,
			arguments: .object([:]),
			chatId: .main,
			scope: turnScope()
		).outcome
		guard case .result(let athleteJSON) = athlete else {
			Issue.record("expected athlete")
			return
		}
		#expect(unwrapData(athleteJSON).objectFields["name"]?.stringValue == "Ada Kovač")

		_ = try await tools.execute(
			name: .intervalsFetchActivity,
			arguments: try JSONValue.parse(#"{"activityId":"i1234567"}"#),
			chatId: .main,
			scope: turnScope()
		).outcome
		_ = try await tools.execute(
			name: .intervalsFetchStreams,
			arguments: try JSONValue.parse(#"{"activityId":"i1234567"}"#),
			chatId: .main,
			scope: turnScope()
		).outcome
		let listed = try await tools.execute(
			name: .intervalsListEvents,
			arguments: try JSONValue.parse(
				#"{"oldest":"1998-06-14","newest":"1998-06-20","coachCreatedOnly":true}"#),
			chatId: .main,
			scope: turnScope()
		).outcome
		#expect(intervals.calls.contains(.activity(activityID)))
		#expect(intervals.calls.contains(.streams(activityID)))
		#expect(intervals.calls.contains(.events(oldest: "1998-06-14", newest: "1998-06-20")))
		guard case .result(let eventsJSON) = listed, let events = unwrapData(eventsJSON).arrayValue
		else {
			Issue.record("expected events")
			return
		}
		#expect(events.count == 1)
		#expect(events[0].objectFields["name"]?.stringValue == "Endurance")
	}

	@Test(arguments: [
		("1998-06-13", "1998-06-13", 1), ("1998-06-14", "1998-06-13", 0),
		("2000-02-28", "2000-03-01", 3), ("1900-02-28", "1900-03-01", 2),
		("1999-12-31", "2000-01-01", 2), ("1583-01-01", "1583-12-31", 365),
	])
	func inclusiveRangesCountGregorianDays(oldest: String, newest: String, days: Int) throws {
		#expect(
			IntervalsPolicy.inclusiveDayCount(
				from: try #require(CivilDate(rawValue: oldest)),
				to: try #require(CivilDate(rawValue: newest))) == days)
	}

	@Test(arguments: [("1998-01-01", "1999-01-02"), ("1583-01-01", "9999-12-31")])
	func rangeTooWideReturnsTypedError(oldest: String, newest: String) async throws {
		let outcome = try await runtime().execute(
			name: .intervalsFetchActivities,
			arguments: .object(["oldest": .string(oldest), "newest": .string(newest)]),
			chatId: .main,
			scope: turnScope()
		).outcome
		guard case .result(let json) = outcome else {
			Issue.record("expected error object")
			return
		}
		#expect(unwrapData(json).objectFields["error"]?.stringValue == "range_too_wide")
		#expect(intervals.calls.isEmpty)
	}

	@Test func toolCatalogSchemasHaveNoUnions() {
		let schemas = ToolCatalog.schemas(
			memory: MemoryView(
				sections: [:],
				todayNotes: nil,
				planHeadline: nil,
				orphanNames: []
			))
		#expect(
			schemas.map(\.name) == [
				.calculateZones,
				.intervalsFetchAthlete,
				.intervalsFetchWellness,
				.intervalsFetchActivity,
				.intervalsFetchStreams,
				.intervalsFetchActivities,
				.intervalsListEvents,
				.intervalsCreateWorkout,
				.intervalsCreateStrengthWorkout,
				.intervalsDeleteWorkout,
				.intervalsUpdateWorkout,
				.memoryQuery,
				.memoryWrite,
				.ledgerAppend,
			]
		)
		let encoded = schemas.map { canonicalJSON($0.parameters) }.joined()
		#expect(!encoded.contains("anyOf"))
		#expect(!encoded.contains("oneOf"))
		#expect(!encoded.contains("allOf"))
		#expect(schemas.contains { $0.description.contains("Form = fitness - fatigue") })
	}

	private func unwrapData(_ json: JSONValue) -> JSONValue {
		json.objectFields["data"] ?? json
	}

	private func runtime() -> ToolRuntime {
		let store = InMemoryRecordLog()
		return makeToolRuntime(
			intervals: intervals,
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		)
	}

	private func turnScope() -> TurnScope {
		TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
	}
}
