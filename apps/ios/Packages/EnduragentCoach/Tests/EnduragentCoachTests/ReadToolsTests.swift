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

	@Test func listedIdentifiersAreAcceptedByTheDetailAndStreamTools() async throws {
		let hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
		intervals.activities = [
			.recorded("i1234567", "Sunday long ride", on: "1998-06-07", at: 8 * 3_600),
			.recorded("17654321", "Tuesday tempo", on: "1998-06-09", at: 7 * 3_600),
			.recorded(hex, nil, on: "1998-06-11"),
		]
		let shown = try await read(.intervalsFetchActivities, #"{"oldest":"1998-06-07"}"#)
		let listed = try #require(shown.objectFields["activities"]?.arrayValue).map {
			$0.objectFields["id"]
		}
		#expect(listed == [.string("i1234567"), .string("17654321"), .string(hex)])
		var expected = [FakeIntervalsCall.activities(oldest: "1998-06-07", newest: "1998-06-13")]
		for value in listed {
			let raw = try #require(value?.stringValue)
			let id = try #require(ActivityID(rawValue: raw))
			let arguments = canonicalJSON(.object(["activityId": .string(raw)]))
			#expect(
				try await read(.intervalsFetchActivity, arguments).objectFields["error"] == nil)
			#expect(
				try await read(.intervalsFetchStreams, arguments).objectFields["error"] == nil)
			expected += [.activity(id), .streams(id, channels: StreamChannels.standard.names)]
		}
		#expect(intervals.calls == expected)
	}

	@Test(arguments: [
		(#"{}"#, "invalid_date"),
		(#"{"newest":"1998-06-13"}"#, "invalid_date"),
		(#"{"oldest":"1998-02-30","newest":"1998-06-13"}"#, "invalid_date"),
		(#"{"oldest":"1998-06-07","newest":"13-06-1998"}"#, "invalid_date"),
		(#"{"oldest":19980607}"#, "invalid_date"),
		(#"{"oldest":"1998-06-13","newest":"1998-06-07"}"#, "invalid_range"),
		(#"{"oldest":"1998-06-14"}"#, "invalid_range"),
		(#"{"oldest":"1997-06-12","newest":"1998-06-13"}"#, "range_too_wide"),
		(#"{"oldest":"1997-06-12"}"#, "range_too_wide"),
	])
	func activityRangeThatIsNotValidIsRefusedBeforeAnyRead(arguments: String, code: String)
		async throws
	{
		intervals.activities = [.recorded("i1234567", "Sunday long ride", on: "1998-06-13")]
		let shown = try await read(.intervalsFetchActivities, arguments)
		#expect(shown.objectFields["error"]?.stringValue == code)
		#expect(shown.objectFields["activities"] == nil)
		#expect(intervals.count(of: .activities) == 0)
	}

	@Test func activityRangeOf366DaysIsReadAndIncludesBothEnds() async throws {
		intervals.activities = [
			.recorded("i4", "Day after", on: "1998-06-14"),
			.recorded("i3", "Newest day", on: "1998-06-13"),
			.recorded("i2", "Oldest day", on: "1997-06-13"),
			.recorded("i1", "Day before", on: "1997-06-12"),
		]
		let shown = try await read(
			.intervalsFetchActivities, #"{"oldest":"1997-06-13","newest":"1998-06-13"}"#)
		#expect(intervals.count(of: .activities) == 1)
		#expect(shown.objectFields["oldest"] == .string("1997-06-13"))
		#expect(shown.objectFields["newest"] == .string("1998-06-13"))
		#expect(identifiers(in: shown) == ["i2", "i3"])
	}

	@Test(arguments: [
		("1998-06-13T00:30:00+02:00", "Europe/Amsterdam"),
		("1998-06-13T23:30:00-04:00", "America/New_York"),
	])
	func omittedNewestOfAnActivityRangeIsTodayInThePhonesTimeZone(now: String, zone: String)
		async throws
	{
		let phone = FixedClock(now: now, timeZone: zone)
		#expect(IntervalsPolicy.today(now: phone.now, timeZone: .gmt) != "1998-06-13")
		intervals.activities = [
			.recorded("i1", "Yesterday", on: "1998-06-12"),
			.recorded("i2", "Today", on: "1998-06-13"),
			.recorded("i3", "Tomorrow", on: "1998-06-14"),
		]
		let shown = try await read(
			.intervalsFetchActivities, #"{"oldest":"1998-06-12"}"#, clock: phone)
		#expect(intervals.calls == [.activities(oldest: "1998-06-12", newest: "1998-06-13")])
		#expect(shown.objectFields["newest"] == .string("1998-06-13"))
		#expect(identifiers(in: shown) == ["i1", "i2"])
	}

	@Test(arguments: [
		ToolName.intervalsFetchActivities, .intervalsFetchWellness, .intervalsListEvents,
	])
	func daysWithoutOldestIsRefusedAsAMissingDate(tool: ToolName) async throws {
		let shown = try await read(tool, #"{"days":7}"#)
		#expect(shown.objectFields["error"] == .string("invalid_date"))
		#expect(
			shown.objectFields["details"]
				== .string("oldest is not a real calendar date. Use YYYY-MM-DD."))
		#expect(intervals.calls.isEmpty)
		#expect(intervals.count(of: .activities) == 0)
		#expect(intervals.count(of: .wellness) == 0)
	}

	@Test func daysBesideOldestChangesNothing() async throws {
		_ = try await read(.intervalsFetchActivities, #"{"oldest":"1998-06-12","days":400}"#)
		_ = try await read(.intervalsFetchWellness, #"{"oldest":"1998-06-12","days":400}"#)
		_ = try await read(.intervalsListEvents, #"{"oldest":"1998-06-12","days":400}"#)
		#expect(
			intervals.calls == [
				.activities(oldest: "1998-06-12", newest: "1998-06-13"),
				.wellness(oldest: "1998-06-12", newest: "1998-06-13"),
				.events(oldest: "1998-06-12", newest: "1998-06-13"),
			])
	}

	@Test func rangeWithNoActivityStillCarriesWhatItHides() async throws {
		intervals.stravaHidden = ["1998-06-08", "1998-06-09", "1998-05-01"]
		intervals.unreadable = ["1998-06-10", "1998-05-02"]
		let shown = try await read(.intervalsFetchActivities, #"{"oldest":"1998-06-07"}"#)
		#expect(shown.objectFields["activities"] == .array([]))
		#expect(shown.objectFields["hiddenByStrava"] == .number(2))
		#expect(shown.objectFields["unreadable"] == .number(1))
		#expect(
			shown.objectFields["stravaNotice"]?.stringValue?.hasPrefix(
				"2 of 3 activities are hidden by Strava") == true)
		#expect(shown.objectFields["units"] == nil)
	}

	@Test(arguments: [
		("1998-06-13T00:30:00+02:00", "Europe/Amsterdam"),
		("1998-06-13T23:30:00-04:00", "America/New_York"),
	])
	func omittedNewestIsTodayInThePhonesTimeZone(now: String, zone: String) async throws {
		let phone = FixedClock(now: now, timeZone: zone)
		#expect(IntervalsPolicy.today(now: phone.now, timeZone: .gmt) != "1998-06-13")
		intervals.wellness = [
			.on("1998-06-12", [.fitness: 54]), .on("1998-06-13", [.fitness: 55]),
			.on("1998-06-14", [.fitness: 56]),
		]
		let shown = try await wellness(#"{"oldest":"1998-06-12"}"#, clock: phone)
		#expect(intervals.calls == [.wellness(oldest: "1998-06-12", newest: "1998-06-13")])
		#expect(shown.objectFields["newest"] == .string("1998-06-13"))
		#expect(dates(in: shown) == ["1998-06-12", "1998-06-13"])
	}

	@Test(arguments: [
		(#"{"oldest":"1998-02-30","newest":"1998-06-13"}"#, "invalid_date"),
		(#"{"oldest":"1998-06-07","newest":"13-06-1998"}"#, "invalid_date"),
		(#"{"oldest":"1998-06-07","newest":19980613}"#, "invalid_date"),
		(#"{"oldest":"1998-06-13","newest":"1998-06-07"}"#, "invalid_range"),
		(#"{"oldest":"1998-06-14"}"#, "invalid_range"),
		(#"{"oldest":"1997-06-12","newest":"1998-06-13"}"#, "range_too_wide"),
		(#"{"oldest":"1997-06-12"}"#, "range_too_wide"),
	])
	func wellnessRangeThatIsNotValidIsRefusedBeforeAnyRead(arguments: String, code: String)
		async throws
	{
		intervals.wellness = [.on("1998-06-13", [.fitness: 55])]
		let shown = try await wellness(arguments, clock: clock)
		#expect(shown.objectFields["error"]?.stringValue == code)
		#expect(shown.objectFields["days"] == nil)
		#expect(intervals.count(of: .wellness) == 0)
	}

	@Test func wellnessRangeOf366DaysIsReadAndIncludesBothEnds() async throws {
		intervals.wellness = [
			.on("1998-06-14", [.fitness: 56]), .on("1998-06-13", [.fitness: 55]),
			.on("1997-06-13", [.fitness: 41]), .on("1997-06-12", [.fitness: 40]),
		]
		let shown = try await wellness(
			#"{"oldest":"1997-06-13","newest":"1998-06-13"}"#, clock: clock)
		#expect(intervals.count(of: .wellness) == 1)
		#expect(shown.objectFields["oldest"] == .string("1997-06-13"))
		#expect(shown.objectFields["newest"] == .string("1998-06-13"))
		#expect(dates(in: shown) == ["1997-06-13", "1998-06-13"])
	}

	@Test func fetchAthleteAndActivityAndStreamsAndEvents() async throws {
		let activityID = try #require(ActivityID(rawValue: "i1234567"))
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
			scope: turnScope()
		).outcome
		_ = try await tools.execute(
			name: .intervalsFetchStreams,
			arguments: try JSONValue.parse(#"{"activityId":"i1234567"}"#),
			scope: turnScope()
		).outcome
		let listed = try await tools.execute(
			name: .intervalsListEvents,
			arguments: try JSONValue.parse(
				#"{"oldest":"1998-06-14","newest":"1998-06-20","coachCreatedOnly":true}"#),
			scope: turnScope()
		).outcome
		#expect(intervals.calls.contains(.activity(activityID)))
		#expect(
			intervals.calls.contains(
				.streams(activityID, channels: StreamChannels.standard.names)))
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
		#"{"activityId":"i1234567"}"#, #"{"activityId":"i1234567","types":[]}"#,
		#"{"activityId":"i1234567","types":null}"#,
	])
	func streamReadWithNoChannelNamedAsksForTheStandardFive(arguments: String) async throws {
		let shown = try await read(.intervalsFetchStreams, arguments)
		let standard = ["watts", "heartrate", "cadence", "time", "altitude"]
		#expect(
			intervals.calls == [
				.streams(try #require(ActivityID(rawValue: "i1234567")), channels: standard)
			])
		#expect(shown.objectFields["unanswered"] == .array(standard.map(JSONValue.string)))
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
			scope: turnScope()
		).outcome
		guard case .result(let json) = outcome else {
			Issue.record("expected error object")
			return
		}
		#expect(unwrapData(json).objectFields["error"]?.stringValue == "range_too_wide")
		#expect(intervals.calls.isEmpty)
	}

	@Test func offeredSchemasHaveNoUnions() {
		let schemas = makeToolOffer(
			training: connectedTraining(intervals),
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		).schemas
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

	private func wellness(_ arguments: String, clock: FixedClock) async throws -> JSONValue {
		try await read(.intervalsFetchWellness, arguments, clock: clock)
	}

	private func read(_ tool: ToolName, _ arguments: String, clock: FixedClock? = nil)
		async throws -> JSONValue
	{
		let outcome = try await runtime(clock: clock ?? self.clock).execute(
			name: tool, arguments: try JSONValue.parse(arguments), scope: turnScope()
		).outcome
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "no_result", details: "\(outcome)")
		}
		return unwrapData(json)
	}

	private func identifiers(in shown: JSONValue) -> [String?]? {
		shown.objectFields["activities"]?.arrayValue?.map { $0.objectFields["id"]?.stringValue }
	}

	private func dates(in shown: JSONValue) -> [String?]? {
		shown.objectFields["days"]?.arrayValue?.map { $0.objectFields["date"]?.stringValue }
	}

	private func runtime() -> ToolRuntime {
		runtime(clock: clock)
	}

	private func runtime(clock: FixedClock) -> ToolRuntime {
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
