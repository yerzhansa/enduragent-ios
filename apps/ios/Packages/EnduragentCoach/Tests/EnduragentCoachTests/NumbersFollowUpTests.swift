import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

enum NumbersFollowUpDepth: String, CaseIterable, Sendable {
	case brief = "/review brief"
	case standard = "/review"
	case deep = "/review deep"

	var reads: [ScriptedEvent] {
		let list: [ScriptedEvent] = [NumbersFollowUpTests.listCall, .finish(reason: .toolCalls)]
		let detail = NumbersFollowUpTests.detailCall(NumbersFollowUpTests.ride)
		switch self {
		case .brief: return list
		case .standard: return list + [detail, .finish(reason: .toolCalls)]
		case .deep:
			return list + [detail, NumbersFollowUpTests.streamCall, .finish(reason: .toolCalls)]
		}
	}

	var readSteps: [[FakeIntervalsCall]] {
		let ride = NumbersFollowUpTests.ride.id
		let list = FakeIntervalsCall.activities(oldest: "1998-06-07", newest: "1998-06-13")
		switch self {
		case .brief: return [[list]]
		case .standard: return [[list], [.activity(ride)]]
		case .deep:
			return [[list], [.activity(ride), .streams(ride, channels: ["watts", "heartrate"])]]
		}
	}
}

struct NumbersFollowUpTurn {
	let review: [CompletionRequest]
	let requests: [CompletionRequest]

	var opening: CompletionRequest {
		get throws { try #require(requests.first) }
	}

	var results: [JSONValue] {
		get throws {
			try #require(requests.last).messages.filter { $0.role == .tool }.map {
				try #require(try JSONValue.parse($0.content).objectFields["data"])
			}
		}
	}

	var everyMessage: [WireMessage] { (review + requests).flatMap(\.messages) }
}

@Suite struct NumbersFollowUpTests {
	static let ride = Activity.recorded(
		"i1234569", "Lunch ride", on: "1998-06-10", at: 12 * 3_600 + 15 * 60, ftp: 250,
		[
			.duration: 3_000, .distance: 27_500, .load: 61, .intensity: 78, .averagePower: 182,
			.weightedPower: 196, .averageHeartRate: 141, .maxHeartRate: 172,
			.elevationGain: 310,
		])
	static let undated = Activity.recorded(
		"i1234571", "Manual entry", on: "1998-06-09", [.duration: 1_800])
	static let reviewReply =
		"A steady hour. I cannot judge how it went from the record alone.\n\nReply 'show numbers' for the full breakdown."
	static let numbersReply = "| Metric | Value |\n|---|---|\n| Sport | Ride |"
	static let listCall = ScriptedEvent.toolCall(
		name: "intervals_fetch_activities", arguments: #"{"oldest":"1998-06-07"}"#)
	static let streamCall = ScriptedEvent.toolCall(
		name: "intervals_fetch_streams",
		arguments: #"{"activityId":"i1234569","types":["watts","heartrate"]}"#)
	static let streamStatistics =
		#"{"sampleCount":4,"channels":{"watts":{"min":100,"max":300,"mean":200},"heartrate":{"min":120,"max":165,"mean":145}}}"#

	static func detailCall(_ activity: Activity) -> ScriptedEvent {
		.toolCall(
			name: "intervals_fetch_activity",
			arguments: #"{"activityId":"\#(activity.id.rawValue)"}"#)
	}

	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test(arguments: NumbersFollowUpDepth.allCases)
	func showNumbersReachesTheCoachWithItsRulesTheReviewReplyAndTheActivityReads(
		after depth: NumbersFollowUpDepth
	) async throws {
		let request = try await followUp(after: depth).opening
		let system = try #require(request.messages.first)
		try #require(system.role == .system)
		let carried = try CarriedReviewTexts(system: system.content, tools: request.tools)

		#expect(
			carried.rules.says(
				"### Show-numbers follow-up format When the athlete replies \"show numbers\" (or \"give me the table\", \"the data\", \"details\", etc.): - After Tier A → emit the Tier B numeric breakdown. - After Tier B / C → emit a compact markdown table."
			))
		#expect(
			carried.rules.says(
				"with one row per available summary metric the sport reports. When lap data is supplied, follow the headline table with a lap table (one row per lap)."
			))
		#expect(carried.rules.says("Render nullable lap cells as unavailable."))
		#expect(carried.topic.says("## Show numbers — the cycling rows Summary/detail table rows:"))
		#expect(carried.topic.says("Render a missing value as unavailable rather than zero."))
		let history = request.messages.dropFirst()
		#expect(history.map(\.role) == [.user, .assistant, .user])
		#expect(history.map(\.unstampedContent).prefix(2) == [depth.rawValue, Self.reviewReply])
		#expect(
			history.last?.content.components(separatedBy: "\nCurrent time:").first
				== "show numbers")
		for tool in CarriedReviewTexts.activityTools {
			#expect(request.tools.contains { $0.name == tool }, "\(tool.rawValue) is not offered")
		}
	}

	@Test(arguments: NumbersFollowUpDepth.allCases)
	func detailReadOnTheFollowUpReturnsTheRecordedSummaryAndLapValuesUnchanged(
		after depth: NumbersFollowUpDepth
	) async throws {
		let turn = try await followUp(after: depth, calling: [[Self.detailCall(Self.ride)]])

		let detail = try #require(try turn.results.first)
		#expect(
			detail
				== (try JSONValue.parse(
					#"{"activity":{"id":"i1234569","name":"Lunch ride","sport":"Ride","start":"1998-06-10T12:15:00","durationSeconds":3000,"distance":27500,"load":61,"intensity":78,"averagePower":182,"weightedPower":196,"averageHeartRate":141,"maxHeartRate":172,"ftp":250,"elevationGain":310,"notes":"Felt steady.","indoor":false,"rpe":6,"averageCadence":88,"work":546000},"laps":[{"number":1,"label":"Warm-up","kind":"RECOVERY","durationSeconds":600,"distance":4800,"averagePower":140,"averageHeartRate":118},{"number":2,"kind":"WORK","durationSeconds":1200},{"number":3,"label":"Cool-down","durationSeconds":1200,"distance":0,"averagePower":95}],"units":{"durationSeconds":"s","distance":"m","intensity":"%","averagePower":"W","weightedPower":"W","averageHeartRate":"bpm","maxHeartRate":"bpm","ftp":"W","elevationGain":"m","averageCadence":"rpm","work":"J"}}"#
				)), "\(canonicalJSON(detail))")
		let laps = try #require(detail.objectFields["laps"]?.arrayValue)
		try #require(laps.count == 3)
		#expect(Set(laps[1].objectFields.keys) == ["number", "kind", "durationSeconds"])
		#expect(laps[2].objectFields["distance"] == .number(0))
		#expect(laps[2].objectFields["averageHeartRate"] == nil)
		let steps = depth.readSteps + [[.activity(Self.ride.id)]]
		#expect(activityReads(inStepsLike: steps) == steps)
	}

	@Test func startReachesTheCoachAsTheRecordedLocalTimeOrTheDateAloneAndNothingCallsItUTC()
		async throws
	{
		let turn = try await followUp(
			after: .standard,
			calling: [
				[Self.listCall], [Self.detailCall(Self.ride), Self.detailCall(Self.undated)],
			])

		let results = try turn.results
		try #require(results.count == 3)
		let listed = try #require(results[0].objectFields["activities"]?.arrayValue)
		#expect(
			listed.map { $0.objectFields["start"] } == [
				.string("1998-06-10T12:15:00"), .string("1998-06-09"),
			])
		#expect(listed.map { $0.objectFields["id"] } == [.string("i1234569"), .string("i1234571")])
		#expect(
			results[1].objectFields["activity"]?.objectFields["start"]
				== .string("1998-06-10T12:15:00"))
		#expect(results[2].objectFields["activity"]?.objectFields["start"] == .string("1998-06-09"))
		let said =
			turn.everyMessage.map { message in
				(
					"a \(message.role.rawValue) message",
					message.role == .user
						? message.content.components(separatedBy: "\nCurrent time:")[0]
						: message.content
				)
			}
			+ (try turn.opening.tools.map {
				($0.name.rawValue, $0.description + $0.parameters.canonicalDigestInput())
			})
		for (name, text) in said {
			for label in ["UTC", "GMT", "Zulu", "+02:00", "+00:00", ":00Z"] {
				#expect(!text.contains(label), "\(name) says \(label)")
			}
		}
	}

	@Test func detailReadAfterABriefReviewIsAnsweredAndBringsNoStreamStatistics() async throws {
		let turn = try await followUp(after: .brief, calling: [[Self.detailCall(Self.ride)]])

		let detail = try #require(try turn.results.first).objectFields
		#expect(detail["error"] == nil)
		#expect(detail["activity"]?.objectFields["id"] == .string("i1234569"))
		#expect(detail["laps"]?.arrayValue?.count == 3)
		#expect(
			activityReads == [
				.activities(oldest: "1998-06-07", newest: "1998-06-13"), .activity(Self.ride.id),
			])
		#expect(intervals.count(of: .streams) == 0)
		#expect(streamStatistics(in: turn.everyMessage).isEmpty)
	}

	@Test func streamStatisticsReachTheCoachOnlyAsTheResultOfAStreamReadOnThatTurn() async throws {
		let turn = try await followUp(
			after: .deep, calling: [[Self.detailCall(Self.ride)], [Self.streamCall]])

		try #require(turn.requests.count == 3)
		#expect(streamStatistics(in: turn.requests[0].messages).isEmpty)
		#expect(streamStatistics(in: turn.requests[1].messages).isEmpty)
		#expect(turn.requests[1].messages.filter { $0.role == .tool }.count == 1)
		let carried = streamStatistics(in: turn.requests[2].messages)
		#expect(carried.map(\.role) == [.tool])
		#expect(carried.first == turn.requests[2].messages.last)
		#expect(try turn.results.last == (try JSONValue.parse(Self.streamStatistics)))
		#expect(intervals.count(of: .streams) == 2)
	}

	@Test func followUpWithNoConnectionOffersNoActivityRead() async throws {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		transport.respond = ScriptedReply.sequence(
			[
				.text("Connect intervals.icu in Settings first."), .finish(reason: .stop),
				.text("I have no numbers to show."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock,
			secrets: secrets)

		_ = try await coach.sendAndSettle("/review")
		_ = try await coach.sendAndSettle("show numbers")

		let requests = sent(.chatAttempt, by: transport)
		try #require(requests.count == 2)
		let offered = requests[1].tools.map(\.name)
		try #require(!offered.isEmpty)
		for tool in CarriedReviewTexts.activityTools {
			#expect(!offered.contains(tool), "\(tool.rawValue) is offered with no connection")
		}
		#expect(
			requests[1].messages.dropFirst().map(\.unstampedContent).prefix(2) == [
				"/review", "Connect intervals.icu in Settings first.",
			])
		#expect(intervals.calls.isEmpty)
	}

	private func followUp(
		after depth: NumbersFollowUpDepth, calling steps: [[ScriptedEvent]] = []
	) async throws -> NumbersFollowUpTurn {
		intervals.activities = [Self.ride, Self.undated]
		intervals.details[Self.ride.id] = .found(
			try ActivityDetail(
				asked: Self.ride.id, activity: Self.ride,
				extras: ActivityDetailExtras(
					notes: "Felt steady.", indoor: false,
					readings: Readings([
						.perceivedExertion: 6, .averageCadence: 88, .work: 546_000,
					])),
				laps: .recorded([
					ActivityLap(
						number: 1, label: "Warm-up", kind: "RECOVERY",
						readings: Readings([
							.duration: 600, .distance: 4_800, .averagePower: 140,
							.averageHeartRate: 118,
						])),
					ActivityLap(
						number: 2, label: nil, kind: "WORK", readings: Readings([.duration: 1_200])),
					ActivityLap(
						number: 3, label: "Cool-down", kind: nil,
						readings: Readings([.duration: 1_200, .distance: 0, .averagePower: 95])),
				])))
		intervals.streams[Self.ride.id] = [
			StreamSamples(channel: "watts", values: [100, nil, 300, 200]),
			StreamSamples(channel: "heartrate", values: [120, 150, 165]),
		]
		transport.respond = ScriptedReply.sequence(
			depth.reads + [.text(Self.reviewReply), .finish(reason: .stop)]
				+ steps.flatMap { $0 + [.finish(reason: .toolCalls)] }
				+ [.text(Self.numbersReply), .finish(reason: .stop)],
			otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		#expect(replyText(try await coach.sendAndSettle(depth.rawValue)) == Self.reviewReply)
		let review = sent(.chatAttempt, by: transport)
		#expect(activityReads(inStepsLike: depth.readSteps) == depth.readSteps)
		#expect(replyText(try await coach.sendAndSettle("show numbers")) == Self.numbersReply)

		return NumbersFollowUpTurn(
			review: review,
			requests: Array(sent(.chatAttempt, by: transport).dropFirst(review.count)))
	}

	private var activityReads: [FakeIntervalsCall] {
		intervals.calls.filter {
			if case .wellness = $0 { return false }
			return $0 != .profile
		}
	}

	private func activityReads(inStepsLike steps: [[FakeIntervalsCall]]) -> [[FakeIntervalsCall]] {
		var later = activityReads[...]
		let made = steps.map { step in
			var unexpected = Array(later.prefix(step.count))
			later = later.dropFirst(step.count)
			let expected = step.filter { call in
				guard let index = unexpected.firstIndex(of: call) else { return false }
				unexpected.remove(at: index)
				return true
			}
			return expected + unexpected
		}
		return later.isEmpty ? made : made + [Array(later)]
	}

	private func streamStatistics(in messages: [WireMessage]) -> [WireMessage] {
		messages.filter { message in
			["sampleCount", "\"channels\"", "\"mean\""].contains { message.content.contains($0) }
		}
	}
}
