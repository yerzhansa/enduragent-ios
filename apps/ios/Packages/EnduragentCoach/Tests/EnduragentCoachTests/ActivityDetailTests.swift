import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ActivityDetailTests {
	static let noon = Activity.recorded(
		"i1234569", "Lunch ride", on: "1998-06-10", at: 12 * 3_600 + 15 * 60, [.duration: 3_000])
	static let evening = Activity.recorded(
		"i1234570", "Lunch ride", on: "1998-06-10", at: 18 * 3_600 + 5, [.duration: 2_700])
	static let unavailable = IntervalsError(code: "http", details: "status 503", status: 503)

	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func detailIsBuiltOnlyForTheIdentifierThatWasAsked() throws {
		let own = try ActivityDetail(
			asked: Self.noon.id, activity: Self.noon, extras: ActivityDetailExtras(),
			laps: .notSupplied)
		#expect(own.activity == Self.noon)
		#expect {
			try ActivityDetail(
				asked: Self.evening.id, activity: Self.noon, extras: ActivityDetailExtras(),
				laps: .notSupplied)
		} throws: {
			($0 as? IntervalsError)?.code == "activity_mismatch"
		}
	}

	@Test func twoActivitiesWithTheSameDayAndTitleAreEachReadWithTheirOwnLaps() async throws {
		intervals.activities = [Self.evening, Self.noon]
		intervals.details[Self.noon.id] = try found(
			Self.noon,
			laps: .recorded([
				ActivityLap(
					number: 1, label: "Warm-up", kind: "RECOVERY",
					readings: Readings([.duration: 600, .averagePower: 140])),
				ActivityLap(
					number: 2, label: nil, kind: "WORK",
					readings: Readings([.duration: 1_200, .distance: 11_400])),
			]))
		intervals.details[Self.evening.id] = try found(
			Self.evening,
			laps: .recorded([
				ActivityLap(
					number: 1, label: "Whole ride", kind: nil,
					readings: Readings([.averageHeartRate: 128]))
			]))
		let listed = try #require(
			try await read(.intervalsFetchActivities, #"{"oldest":"1998-06-10"}"#)
				.objectFields["activities"]?.arrayValue
		).compactMap { $0.objectFields["id"]?.stringValue }
		#expect(listed == ["i1234569", "i1234570"])
		#expect(
			try await detail(of: listed[0])
				== (try JSONValue.parse(
					#"{"activity":{"id":"i1234569","name":"Lunch ride","sport":"Ride","start":"1998-06-10T12:15:00","durationSeconds":3000},"laps":[{"number":1,"label":"Warm-up","kind":"RECOVERY","durationSeconds":600,"averagePower":140},{"number":2,"kind":"WORK","durationSeconds":1200,"distance":11400}],"units":{"durationSeconds":"s","averagePower":"W","distance":"m"}}"#
				)))
		#expect(
			try await detail(of: listed[1])
				== (try JSONValue.parse(
					#"{"activity":{"id":"i1234570","name":"Lunch ride","sport":"Ride","start":"1998-06-10T18:00:05","durationSeconds":2700},"laps":[{"number":1,"label":"Whole ride","averageHeartRate":128}],"units":{"durationSeconds":"s","averageHeartRate":"bpm"}}"#
				)))
	}

	@Test func lapsNotSuppliedAndLapsRecordedAsAnEmptyListAreToldApart() async throws {
		intervals.activities = [Self.noon, Self.evening]
		intervals.details[Self.evening.id] = try found(Self.evening, laps: .recorded([]))
		let stored = try await detail(of: "i1234569").objectFields
		#expect(stored["lapsSupplied"] == .bool(false))
		#expect(stored["laps"] == nil)
		#expect(stored["activity"]?.objectFields["id"] == .string("i1234569"))
		let empty = try await detail(of: "i1234570").objectFields
		#expect(empty["laps"] == .array([]))
		#expect(empty["lapsSupplied"] == nil)
	}

	@Test func detailOnlyFieldsTheSourceSentAreShownAndTheOthersHaveNoKey() async throws {
		intervals.activities = [Self.noon]
		intervals.details[Self.noon.id] = try found(
			Self.noon,
			extras: ActivityDetailExtras(
				notes: "Felt strong.", indoor: true,
				readings: Readings([.perceivedExertion: 7, .work: 540_000]),
				powerZoneSeconds: [ZoneSeconds(zone: "Z2", seconds: 1_500)]),
			laps: .notSupplied)
		#expect(
			try await detail(of: "i1234569")
				== (try JSONValue.parse(
					#"{"activity":{"id":"i1234569","name":"Lunch ride","sport":"Ride","start":"1998-06-10T12:15:00","durationSeconds":3000,"notes":"Felt strong.","indoor":true,"rpe":7,"work":540000,"powerZoneSeconds":[{"zone":"Z2","seconds":1500}]},"lapsSupplied":false,"units":{"durationSeconds":"s","work":"J","powerZoneSeconds":"s"}}"#
				)))
	}

	@Test func identifierIntervalsDoesNotHaveIsNotFound() async throws {
		intervals.activities = [Self.noon]
		let shown = try await detail(of: "i1234570").objectFields
		#expect(shown["error"] == .string("activity_not_found"))
		#expect(shown["activityId"] == .string("i1234570"))
		#expect(Set(shown.keys) == ["error", "activityId", "details"])
		#expect(intervals.calls == [.activity(Self.evening.id)])
	}

	@Test func activityStravaHidesCarriesTheImportGuidance() async throws {
		intervals.activities = [Self.noon]
		intervals.details[Self.noon.id] = .hiddenByStrava
		let shown = try await detail(of: "i1234569").objectFields
		#expect(shown["error"] == .string("activity_hidden_by_strava"))
		#expect(shown["activityId"] == .string("i1234569"))
		#expect(Set(shown.keys) == ["error", "activityId", "details"])
		let details = try #require(shown["details"]?.stringValue)
		let notice = CoachReadout.stravaNotice(hidden: 1, of: 1)
		let guidance = try #require(notice.range(of: "Strava does not allow"))
		#expect(details.hasSuffix(notice[guidance.lowerBound...]))
	}

	@Test func detailThatFailsAfterAGoodListNamesTheActivityAndTheCause() async throws {
		intervals.activities = [Self.noon, Self.evening]
		let listed = try await read(.intervalsFetchActivities, #"{"oldest":"1998-06-10"}"#)
		#expect(listed.objectFields["activities"]?.arrayValue?.count == 2)
		intervals.fail(.activity, with: Self.unavailable)

		let shown = try await detail(of: "i1234569").objectFields

		#expect(shown["error"] == .string("activity_detail_unavailable"))
		#expect(shown["activityId"] == .string("i1234569"))
		#expect(shown["cause"] == .string("http"))
		#expect(shown["details"]?.stringValue?.contains("status 503") == true)
		#expect(Set(shown.keys) == ["error", "activityId", "cause", "details"])
		#expect(!canonicalJSON(.object(shown)).contains("i1234570"))
		#expect(
			intervals.calls == [
				.activities(oldest: "1998-06-10", newest: "1998-06-13"), .activity(Self.noon.id),
			])
	}

	@Test func storedAnswerForAnotherIdentifierIsNeverShownAsTheAskedActivity() async throws {
		intervals.activities = [Self.noon, Self.evening]
		intervals.details[Self.noon.id] = try found(Self.evening, laps: .recorded([]))
		let shown = try await detail(of: "i1234569").objectFields
		#expect(shown["error"] == .string("activity_detail_unavailable"))
		#expect(shown["cause"] == .string("activity_mismatch"))
		#expect(shown["activityId"] == .string("i1234569"))
		#expect(shown["activity"] == nil)
		#expect(!canonicalJSON(.object(shown)).contains("i1234570"))
	}

	@Test(arguments: [
		#"{}"#, #"{"activityId":""}"#, #"{"activityId":"i"}"#, #"{"activityId":"ride-7"}"#,
		#"{"activityId":"I1234569"}"#, #"{"activityId":-5}"#, #"{"activityId":1.5}"#,
		#"{"activityId":null}"#, #"{"activityId":["i1234569"]}"#,
		#"{"activityId":"0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"}"#,
	])
	func identifierTheToolCannotAcceptIsRefusedBeforeAnyRead(arguments: String) async throws {
		intervals.activities = [Self.noon]
		let shown = try await read(.intervalsFetchActivity, arguments).objectFields
		#expect(shown["error"] == .string("invalid_input"))
		#expect(intervals.count(of: .activity) == 0)
		#expect(intervals.calls.isEmpty)
	}

	@Test func lapListBeyondTheTokenCapIsOmittedAndCounted() async throws {
		intervals.activities = [Self.noon, Self.evening]
		intervals.details[Self.noon.id] = try found(Self.noon, laps: .recorded(laps(2_000)))
		intervals.details[Self.evening.id] = try found(Self.evening, laps: .recorded(laps(100)))
		let long = try await outcome(.intervalsFetchActivity, #"{"activityId":"i1234569"}"#)
		guard case .truncated(_, let estimated, let omitted) = long else {
			Issue.record("expected the long lap list to be omitted, got \(long)")
			return
		}
		#expect(estimated > TurnPolicy.toolResultTokenCap)
		#expect(omitted == 2_000)
		let short = try await detail(of: "i1234570")
		#expect(short.objectFields["laps"]?.arrayValue?.count == 100)
	}

	private func laps(_ count: Int) -> [ActivityLap] {
		(1...count).map { number in
			ActivityLap(
				number: number, label: "Lap \(number)",
				kind: number.isMultiple(of: 2) ? "WORK" : "RECOVERY",
				readings: Readings([
					.duration: 300, .distance: 2_400.5, .load: 4, .intensity: 82,
					.averagePower: 205, .weightedPower: 208, .averageHeartRate: 148,
					.maxHeartRate: 161, .elevationGain: 3.5,
				]))
		}
	}

	private func found(
		_ activity: Activity, extras: ActivityDetailExtras = ActivityDetailExtras(), laps: Laps
	) throws -> ActivityDetailRead {
		.found(
			try ActivityDetail(asked: activity.id, activity: activity, extras: extras, laps: laps))
	}

	private func detail(of id: String) async throws -> JSONValue {
		try await read(
			.intervalsFetchActivity, canonicalJSON(.object(["activityId": .string(id)])))
	}

	private func read(_ tool: ToolName, _ arguments: String) async throws -> JSONValue {
		let outcome = try await outcome(tool, arguments)
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "no_result", details: "\(outcome)")
		}
		return try #require(json.objectFields["data"])
	}

	private func outcome(_ tool: ToolName, _ arguments: String) async throws -> ToolOutcome {
		try await makeToolRuntime(
			intervals: intervals,
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		).execute(
			name: tool, arguments: try JSONValue.parse(arguments),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		).outcome
	}
}
