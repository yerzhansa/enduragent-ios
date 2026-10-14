import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct StreamReadTests {
	static let ride = Activity.recorded("i1234567", "Sunday long ride", on: "1998-06-07")

	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func namedChannelsAreForwardedAndSummarizedFromTheStoredSamples() async throws {
		intervals.streams[Self.ride.id] = [
			StreamSamples(channel: "watts", values: [100, nil, 300]),
			StreamSamples(channel: "smooth_grade", values: [1.5, -2.5, 0.5]),
			StreamSamples(channel: "cadence", values: [90, 90, 90, 90, 90]),
			StreamSamples(channel: "temp", values: [nil, nil, nil, nil]),
		]
		let shown = try await read(
			#"{"activityId":"i1234567","types":["smooth_grade","watts","temp","torque"]}"#)
		#expect(
			shown
				== (try JSONValue.parse(
					#"{"sampleCount":3,"channels":{"smooth_grade":{"min":-2.5,"max":1.5,"mean":-0.2},"watts":{"min":100,"max":300,"mean":200}},"unanswered":["temp","torque"]}"#
				)), "\(canonicalJSON(shown))")
		#expect(
			intervals.calls == [
				.streams(Self.ride.id, channels: ["smooth_grade", "watts", "temp", "torque"])
			])
	}

	@Test func streamsOfAnotherActivityAreNotSummarized() async throws {
		intervals.streams[Self.ride.id] = [StreamSamples(channel: "watts", values: [100, 300])]
		let shown = try await read(#"{"activityId":"i7654321","types":["watts"]}"#)
		#expect(
			shown
				== (try JSONValue.parse(#"{"sampleCount":0,"channels":{},"unanswered":["watts"]}"#))
		)
	}

	@Test(arguments: [
		#"{}"#, #"{"types":["watts"]}"#, #"{"activityId":"","types":["watts"]}"#,
		#"{"activityId":"i"}"#, #"{"activityId":"ride-7"}"#, #"{"activityId":-5}"#,
		#"{"activityId":1.5}"#, #"{"activityId":["i1234567"]}"#,
		#"{"activityId":"i1234567","types":"watts"}"#,
		#"{"activityId":"i1234567","types":["watts",7]}"#,
		#"{"activityId":"i1234567","types":{"watts":true}}"#,
		#"{"activityId":"i1234567","types":["watts,grade_smooth"]}"#,
		#"{"activityId":"i1234567","types":["watts",""]}"#,
		#"{"activityId":"i1234567","types":[","]}"#,
	])
	func identifierOrChannelListTheToolCannotAcceptIsRefusedBeforeAnyRead(arguments: String)
		async throws
	{
		intervals.streams[Self.ride.id] = [StreamSamples(channel: "watts", values: [100, 300])]
		let shown = try await read(arguments).objectFields
		#expect(shown["error"] == .string("invalid_input"))
		#expect(shown["channels"] == nil)
		#expect(intervals.count(of: .streams) == 0)
		#expect(intervals.calls.isEmpty)
	}

	@Test func channelNameHoldingACommaIsNamedInTheRefusal() async throws {
		let shown = try await read(
			#"{"activityId":"i1234567","types":["heartrate","watts,grade_smooth"]}"#)
		#expect(
			shown
				== .object([
					"error": .string("invalid_input"),
					"details": .string(
						"types entry \"watts,grade_smooth\" is not one channel name. Give each channel as its own entry, never empty and with no comma."
					),
				]))
		#expect(intervals.calls.isEmpty)
	}

	@Test func streamReadThatFailsIsShownAsItsFailureNotAsAnEmptySummary() async throws {
		intervals.streams[Self.ride.id] = [StreamSamples(channel: "watts", values: [100, 300])]
		intervals.fail(
			.streams, with: IntervalsError(code: "http", details: "status 503", status: 503))
		let shown = try await read(#"{"activityId":"i1234567"}"#).objectFields
		#expect(shown["error"] == .string("http"))
		#expect(shown["status"] == .number(503))
		#expect(shown["channels"] == nil)
		#expect(shown["unanswered"] == nil)
		#expect(intervals.count(of: .streams) == 1)
	}

	private func read(_ arguments: String) async throws -> JSONValue {
		let outcome = try await makeToolRuntime(
			intervals: intervals,
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		).execute(
			name: .intervalsFetchStreams, arguments: try JSONValue.parse(arguments),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		).outcome
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "no_result", details: "\(outcome)")
		}
		return try #require(json.objectFields["data"])
	}
}
