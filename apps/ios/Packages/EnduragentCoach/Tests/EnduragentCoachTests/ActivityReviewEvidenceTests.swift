import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ActivityReviewEvidenceTests {
	static let closing = "That is the record."
	static let lastSevenDays = #"{"oldest":"1998-06-07"}"#
	static let spin = Activity.recorded(
		"i7700101", "Recovery spin", on: "1998-06-09", at: 18 * 3_600,
		[.duration: 2_400, .load: 21]
	)
	static let tempo = Activity.recorded(
		"i7700102", "Thursday tempo", on: "1998-06-11", at: 6 * 3_600 + 45 * 60 + 5,
		[
			.duration: 4_500, .distance: 41_200, .load: 86, .intensity: 83, .averagePower: 205,
			.weightedPower: 221, .averageHeartRate: 148, .maxHeartRate: 171, .ftp: 250,
			.elevationGain: 310,
		])
	static let earlier = Activity.recorded(
		"i7700090", "Long ride", on: "1998-06-01", at: 9 * 3_600, [.duration: 12_600])
	static let noon = Activity.recorded(
		"i7700201", "Lunch ride", on: "1998-06-10", at: 12 * 3_600 + 15 * 60, [.duration: 3_000])
	static let evening = Activity.recorded(
		"i7700202", "Lunch ride", on: "1998-06-10", at: 18 * 3_600 + 5, [.duration: 2_700])

	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test(arguments: [
		"/review", "/review brief", "/review deep", "review saturday's ride",
		"/review Saturday's ride, in depth",
	])
	func athletesWordsReachTheCoachUnchanged(words: String) async throws {
		_ = try await results(of: words, reading: [])

		let athlete = try #require(transport.requests.first).messages.filter { $0.role == .user }
		try #require(athlete.count == 1)
		let lines = athlete[0].content.components(separatedBy: "\n")
		#expect(lines.first == words)
		#expect(lines.count == 2)
		#expect(lines.last?.hasPrefix("Current time: ") == true)
		let stored = try await store.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(stored.map(messageText) == [words])
	}

	@Test func sevenDayListLeadsToOneActivitysDetailAndThenToItsStreams() async throws {
		intervals.activities = [Self.earlier, Self.tempo, Self.spin]
		intervals.details[Self.tempo.id] = .found(
			try ActivityDetail(
				asked: Self.tempo.id, activity: Self.tempo,
				extras: ActivityDetailExtras(
					indoor: false, readings: Readings([.averageCadence: 88])),
				laps: .recorded([
					ActivityLap(
						number: 1, label: "Warm-up", kind: "RECOVERY",
						readings: Readings([.duration: 900, .distance: 7_100, .averagePower: 150])),
					ActivityLap(
						number: 2, label: nil, kind: "WORK",
						readings: Readings([
							.duration: 1_200, .averagePower: 240, .averageHeartRate: 162,
						])),
				])))
		intervals.streams[Self.tempo.id] = [
			StreamSamples(channel: "watts", values: [180, 260, nil, 220]),
			StreamSamples(channel: "heartrate", values: [140, 150, 160, 170]),
		]
		intervals.streams[Self.spin.id] = [StreamSamples(channel: "watts", values: [90, 110])]

		let seen = try await results(
			of: "/review deep",
			reading: [
				ScriptedRead(.intervalsFetchActivities) { _ in
					try JSONValue.parse(Self.lastSevenDays)
				},
				ScriptedRead(.intervalsFetchActivity) { seen in
					let listed = try Self.rows(in: seen[0]).first {
						$0["name"] == .string("Thursday tempo")
					}
					return .object(["activityId": try #require(listed?["id"])])
				},
				ScriptedRead(.intervalsFetchStreams) { seen in
					.object([
						"activityId": try #require(
							seen[1].objectFields["activity"]?.objectFields["id"]),
						"types": .array([.string("watts"), .string("heartrate")]),
					])
				},
			])

		#expect(
			seen[0]
				== (try JSONValue.parse(
					#"{"oldest":"1998-06-07","newest":"1998-06-13","activities":[{"id":"i7700101","name":"Recovery spin","sport":"Ride","start":"1998-06-09T18:00:00","durationSeconds":2400,"load":21},{"id":"i7700102","name":"Thursday tempo","sport":"Ride","start":"1998-06-11T06:45:05","durationSeconds":4500,"distance":41200,"load":86,"intensity":83,"averagePower":205,"weightedPower":221,"averageHeartRate":148,"maxHeartRate":171,"ftp":250,"elevationGain":310}],"hiddenByStrava":0,"units":{"durationSeconds":"s","distance":"m","intensity":"%","averagePower":"W","weightedPower":"W","averageHeartRate":"bpm","maxHeartRate":"bpm","ftp":"W","elevationGain":"m"}}"#
				)), "\(canonicalJSON(seen[0]))")
		#expect(
			seen[1]
				== (try JSONValue.parse(
					#"{"activity":{"id":"i7700102","name":"Thursday tempo","sport":"Ride","start":"1998-06-11T06:45:05","durationSeconds":4500,"distance":41200,"load":86,"intensity":83,"averagePower":205,"weightedPower":221,"averageHeartRate":148,"maxHeartRate":171,"ftp":250,"elevationGain":310,"averageCadence":88,"indoor":false},"laps":[{"number":1,"label":"Warm-up","kind":"RECOVERY","durationSeconds":900,"distance":7100,"averagePower":150},{"number":2,"kind":"WORK","durationSeconds":1200,"averagePower":240,"averageHeartRate":162}],"units":{"durationSeconds":"s","distance":"m","intensity":"%","averagePower":"W","weightedPower":"W","averageHeartRate":"bpm","maxHeartRate":"bpm","ftp":"W","elevationGain":"m","averageCadence":"rpm"}}"#
				)), "\(canonicalJSON(seen[1]))")
		#expect(
			seen[2]
				== (try JSONValue.parse(
					#"{"sampleCount":4,"channels":{"watts":{"min":180,"max":260,"mean":220},"heartrate":{"min":140,"max":170,"mean":155}}}"#
				)), "\(canonicalJSON(seen[2]))")
		#expect(
			activityReads() == [
				.activities(oldest: "1998-06-07", newest: "1998-06-13"), .activity(Self.tempo.id),
				.streams(Self.tempo.id, channels: ["watts", "heartrate"]),
			])
	}

	@Test func twoActivitiesWithTheSameDayAndTitleAreListedApartAndEachIsReadAsItself()
		async throws
	{
		intervals.activities = [Self.evening, Self.noon]

		let seen = try await results(
			of: "/review lunch ride",
			reading: [
				ScriptedRead(.intervalsFetchActivities) { _ in
					try JSONValue.parse(Self.lastSevenDays)
				},
				ScriptedRead(.intervalsFetchActivity) { seen in
					.object(["activityId": try #require(try Self.rows(in: seen[0]).last?["id"])])
				},
				ScriptedRead(.intervalsFetchActivity) { seen in
					.object(["activityId": try #require(try Self.rows(in: seen[0]).first?["id"])])
				},
			])

		let listed = try Self.rows(in: seen[0])
		try #require(listed.count == 2)
		#expect(listed.map { $0["name"] } == [.string("Lunch ride"), .string("Lunch ride")])
		#expect(listed.map { $0["id"] } == [.string("i7700201"), .string("i7700202")])
		#expect(
			listed.map { $0["start"] }
				== [.string("1998-06-10T12:15:00"), .string("1998-06-10T18:00:05")])
		#expect(
			seen[1].objectFields
				== ["activity": .object(listed[1]), "lapsSupplied": .bool(false), "units": units])
		#expect(
			seen[2].objectFields
				== ["activity": .object(listed[0]), "lapsSupplied": .bool(false), "units": units])
		#expect(
			activityReads().dropFirst() == [.activity(Self.evening.id), .activity(Self.noon.id)])
	}

	@Test func startsShowTheTimeOfDayThatTheThirtyMinuteRuleReadsAndADateOnlyStartShowsTheDate()
		async throws
	{
		intervals.activities = [
			.recorded("i7700301", "Morning ride", on: "1998-06-08", at: 7 * 3_600),
			.recorded(
				"i7700302", "Brick run", sport: "Run", on: "1998-06-08", at: 7 * 3_600 + 29 * 60),
			.recorded("i7700303", "Evening ride", on: "1998-06-10", at: 17 * 3_600),
			.recorded(
				"i7700304", "Evening run", sport: "Run", on: "1998-06-10", at: 17 * 3_600 + 31 * 60),
			.recorded("i7700305", "Manual entry", on: "1998-06-12"),
		]

		let seen = try await results(
			of: "/review brief",
			reading: [
				ScriptedRead(.intervalsFetchActivities) { _ in
					try JSONValue.parse(Self.lastSevenDays)
				}
			])

		let starts = try Self.rows(in: seen[0]).map { try #require($0["start"]?.stringValue) }
		#expect(
			starts == [
				"1998-06-08T07:00:00", "1998-06-08T07:29:00", "1998-06-10T17:00:00",
				"1998-06-10T17:31:00", "1998-06-12",
			])
		#expect(try Self.minutes(from: starts[0], to: starts[1]) == 29)
		#expect(try Self.minutes(from: starts[2], to: starts[3]) == 31)
	}

	@Test func emptySevenDayListHasItsCountsAndAnOlderRangeReachesTheNewestActivity()
		async throws
	{
		intervals.activities = [Self.earlier]

		let seen = try await results(
			of: "/review",
			reading: [
				ScriptedRead(.intervalsFetchActivities) { _ in
					try JSONValue.parse(Self.lastSevenDays)
				},
				ScriptedRead(.intervalsFetchActivities) { seen in
					try #require(try Self.rows(in: seen[0]).isEmpty)
					return try JSONValue.parse(#"{"oldest":"1998-05-25","newest":"1998-06-06"}"#)
				},
				ScriptedRead(.intervalsFetchActivity) { seen in
					.object(["activityId": try #require(try Self.rows(in: seen[1]).last?["id"])])
				},
			])

		#expect(
			seen[0]
				== (try JSONValue.parse(
					#"{"oldest":"1998-06-07","newest":"1998-06-13","activities":[],"hiddenByStrava":0}"#
				)), "\(canonicalJSON(seen[0]))")
		#expect(
			seen[1]
				== (try JSONValue.parse(
					#"{"oldest":"1998-05-25","newest":"1998-06-06","activities":[{"id":"i7700090","name":"Long ride","sport":"Ride","start":"1998-06-01T09:00:00","durationSeconds":12600}],"hiddenByStrava":0,"units":{"durationSeconds":"s"}}"#
				)), "\(canonicalJSON(seen[1]))")
		#expect(
			seen[2].objectFields["activity"]
				== (try Self.rows(in: seen[1]).last).map(JSONValue.object))
		#expect(
			activityReads() == [
				.activities(oldest: "1998-06-07", newest: "1998-06-13"),
				.activities(oldest: "1998-05-25", newest: "1998-06-06"),
				.activity(Self.earlier.id),
			])
	}

	@Test(arguments: FailedDetail.allCases)
	func detailReadThatFailsAfterAGoodListGivesItsFailureAnswerAndNoActivityData(
		failure: FailedDetail
	) async throws {
		intervals.activities = [Self.spin, Self.tempo]
		switch failure {
		case .notFound: intervals.details[Self.tempo.id] = .notFound
		case .hiddenByStrava: intervals.details[Self.tempo.id] = .hiddenByStrava
		case .unavailable:
			intervals.fail(
				.activity, with: IntervalsError(code: "http", details: "status 503", status: 503))
		}

		let seen = try await results(
			of: "/review thursday tempo",
			reading: [
				ScriptedRead(.intervalsFetchActivities) { _ in
					try JSONValue.parse(Self.lastSevenDays)
				},
				ScriptedRead(.intervalsFetchActivity) { seen in
					.object(["activityId": try #require(try Self.rows(in: seen[0]).last?["id"])])
				},
			])

		#expect(
			try Self.rows(in: seen[0]).map { $0["id"] }
				== [.string("i7700101"), .string("i7700102")])
		#expect(seen[0].objectFields["error"] == nil)
		let answer = seen[1].objectFields
		#expect(answer["error"] == .string(failure.code))
		#expect(answer["activityId"] == .string("i7700102"))
		#expect(answer["cause"] == failure.cause.map(JSONValue.string))
		#expect(
			Set(answer.keys)
				== Set(
					["error", "activityId", "details"] + (failure.cause == nil ? [] : ["cause"]))
		)
		let details = try #require(answer["details"]?.stringValue)
		#expect(details.contains("i7700102"))
		#expect(details.contains(failure.said))
		for value in ["i7700101", "Thursday tempo", "4500", "1998-06-11"] {
			#expect(!canonicalJSON(seen[1]).contains(value), "the failure answer shows \(value)")
		}
		#expect(activityReads().dropFirst() == [.activity(Self.tempo.id)])
	}

	enum FailedDetail: CaseIterable, Sendable {
		case notFound
		case hiddenByStrava
		case unavailable

		var code: String {
			switch self {
			case .notFound: "activity_not_found"
			case .hiddenByStrava: "activity_hidden_by_strava"
			case .unavailable: "activity_detail_unavailable"
			}
		}

		var cause: String? {
			self == .unavailable ? "http" : nil
		}

		var said: String {
			switch self {
			case .notFound: "intervals.icu has no activity"
			case .hiddenByStrava: "Import All Strava Data"
			case .unavailable: "Cause: status 503"
			}
		}
	}

	struct ScriptedRead: Sendable {
		let tool: ToolName
		let arguments: @Sendable ([JSONValue]) throws -> JSONValue

		init(_ tool: ToolName, arguments: @escaping @Sendable ([JSONValue]) throws -> JSONValue) {
			self.tool = tool
			self.arguments = arguments
		}
	}

	private var units: JSONValue { .object(["durationSeconds": .string("s")]) }

	private func results(of words: String, reading reads: [ScriptedRead]) async throws
		-> [JSONValue]
	{
		let stopped = Mutex<[any Error]>([])
		transport.respond = { request in
			guard request.purpose == .chat, request.step < reads.count else {
				return ScriptedReply([.text(Self.closing), .finish(reason: .stop)])
			}
			do {
				let read = reads[request.step]
				let arguments = try read.arguments(try request.toolResults.map(Self.shown))
				return ScriptedReply([
					.toolCall(name: read.tool.rawValue, arguments: canonicalJSON(arguments)),
					.finish(reason: .toolCalls),
				])
			} catch {
				stopped.withLock { $0.append(error) }
				return ScriptedReply([.text("The script stopped."), .finish(reason: .stop)])
			}
		}
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		let settled = try await coach.sendAndSettle(words)

		if let failure = stopped.withLock({ $0.first }) { throw failure }
		#expect(replyText(settled) == Self.closing)
		try #require(transport.requests.count == reads.count + 1)
		let seen = try transport.requests[reads.count].messages.filter { $0.role == .tool }
			.map { try Self.shown($0.content) }
		try #require(seen.count == reads.count)
		return seen
	}

	private func activityReads() -> [FakeIntervalsCall] {
		intervals.calls.filter {
			switch $0 {
			case .activities, .activity, .streams: true
			case .wellness, .events, .createEvent, .updateEvent, .deleteEvent: false
			}
		}
	}

	private static func shown(_ result: String) throws -> JSONValue {
		try #require(try JSONValue.parse(result).objectFields["data"])
	}

	private static func rows(in listing: JSONValue) throws -> [[String: JSONValue]] {
		try #require(listing.objectFields["activities"]?.arrayValue).map(\.objectFields)
	}

	private static func minutes(from earlier: String, to later: String) throws -> Int {
		let seconds = try [earlier, later].map { start in
			let parts = start.split(separator: "T")
			try #require(parts.count == 2)
			let clock = try parts[1].split(separator: ":").map { try #require(Int($0)) }
			try #require(clock.count == 3)
			return clock[0] * 3_600 + clock[1] * 60 + clock[2]
		}
		try #require(earlier.prefix(10) == later.prefix(10))
		return (seconds[1] - seconds[0]) / 60
	}
}
