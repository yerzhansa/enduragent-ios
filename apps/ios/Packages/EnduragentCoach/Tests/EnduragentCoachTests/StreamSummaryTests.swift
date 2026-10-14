import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Test func customChannelIsAskedForByItsNameAndSummarizedUnderIt() async throws {
		let summary = try await makeClient().streams(
			of: try #require(ActivityID(rawValue: "i1234567")),
			channels: StreamChannels(requested: ["smooth_grade", "watts"]))
		let request = try #require(IntervalsURLProtocolStub.lastRequest)
		#expect(request.url?.path == "/api/v1/activity/i1234567/streams.json")
		#expect(request.url?.query == "types=smooth_grade,watts")
		#expect(request.httpMethod == "GET")
		let custom = try #require(summary.channels["smooth_grade"])
		#expect([custom.min, custom.max, custom.mean] == [-2.5, 1.5, -0.2])
		#expect(summary.unanswered == [])
	}

	@Test(arguments: [nil, []] as [[String]?])
	func standardFiveAreAskedForWhenNoChannelIsNamed(requested: [String]?) async throws {
		_ = try await makeClient().streams(
			of: try #require(ActivityID(rawValue: "i1234567")),
			channels: StreamChannels(requested: requested))
		#expect(
			IntervalsURLProtocolStub.lastRequest?.url?.query
				== "types=watts,heartrate,cadence,time,altitude")
	}

	@Suite struct StreamSummaryTests {
		static let answering = [
			"time", "watts", "heartrate", "cadence", "altitude", "smooth_grade",
		]

		@Test func everyChannelWithAValidSampleIsSummarizedAsNpmDoes() async throws {
			let shown = try await readout(types: Self.answering, answer: try wire())
			#expect(shown == (try npm()), "\(canonicalJSON(shown))")
		}

		@Test func channelsWithNothingToSummarizeAreUnansweredAndHaveNoStatistics() async throws {
			let shown = try await readout(
				types: ["temp", "watts", "dfa_a1", "torque", "left_right_balance", "temp"],
				answer: try wire())
			var expected = try npm().objectFields
			expected["channels"] = .object(
				["watts": try #require(expected["channels"]?.objectFields["watts"])])
			expected["unanswered"] = .array(
				["temp", "dfa_a1", "torque", "left_right_balance"].map(JSONValue.string))
			#expect(shown == .object(expected), "\(canonicalJSON(shown))")
		}

		@Test func sourceThatReturnsNoChannelLeavesTheStandardFiveUnanswered() async throws {
			let shown = try await readout(types: nil, answer: .array([]))
			#expect(
				shown
					== (try JSONValue.parse(
						#"{"sampleCount":0,"channels":{},"unanswered":["watts","heartrate","cadence","time","altitude"]}"#
					)))
		}

		@Test func listAndKeyedLayoutsGiveTheSameSummary() async throws {
			var keyed: [String: JSONValue] = [:]
			for entry in try #require(try wire().arrayValue) {
				let type = try #require(entry.objectFields["type"]?.stringValue)
				keyed[type] = entry.objectFields["data"] ?? .null
			}
			#expect(keyed.count == 9)
			let asked = try StreamChannels(requested: Self.answering + ["temp", "torque"])
			let fromList = try await summary(of: try wire(), asked: asked)
			let fromKeyed = try await summary(of: .object(keyed), asked: asked)
			#expect(fromKeyed == fromList)
			#expect(fromKeyed.sampleCount == 10)
			#expect(Set(fromKeyed.channels.keys) == Set(Self.answering))
			#expect(fromKeyed.unanswered == ["temp", "torque"])
		}

		@Test func samplesThatAreNotFiniteNumbersAreLeftOutOfEveryStatistic() throws {
			let summary = StreamSummary(
				summarizing: [
					StreamSamples(channel: "watts", values: [nil, 250, .infinity, 150, .nan]),
					StreamSamples(channel: "cadence", values: [90]),
					StreamSamples(channel: "temp", values: [nil, .nan, -.infinity, nil, nil, nil]),
				], asked: try StreamChannels(requested: ["watts", "temp", "cadence"]))
			#expect(summary.sampleCount == 5)
			#expect(Set(summary.channels.keys) == ["watts", "cadence"])
			let watts = summary.channels["watts"]
			#expect([watts?.min, watts?.max, watts?.mean] == [150, 250, 200])
			#expect(summary.unanswered == ["temp"])
		}

		@Test(arguments: [#""no streams""#, "7", "null"])
		func answerThatIsNeitherLayoutIsRefused(body: String) async throws {
			let answer = try JSONValue.parse(body)
			await #expect {
				_ = try await summary(of: answer, asked: .standard)
			} throws: {
				($0 as? IntervalsError)?.code == "invalid_json"
			}
		}

		private func wire() throws -> JSONValue {
			try JSONValue.parse(
				String(decoding: try fixtureData("intervals-streams"), as: UTF8.self))
		}

		private func npm() throws -> JSONValue {
			try JSONValue.parse(String(decoding: try fixtureData("streams-ts"), as: UTF8.self))
		}

		private func summary(of answer: JSONValue, asked: StreamChannels) async throws
			-> StreamSummary
		{
			let client = try IntervalsRESTClientTests().makeClient()
			let body = Data(canonicalJSON(answer).utf8)
			IntervalsURLProtocolStub.handler = { _ in (200, body) }
			return try await client.streams(
				of: try #require(ActivityID(rawValue: "i1234567")), channels: asked)
		}

		private func readout(types: [String]?, answer: JSONValue) async throws -> JSONValue {
			let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
			let client = try IntervalsRESTClientTests().makeClient(clock: clock)
			let body = Data(canonicalJSON(answer).utf8)
			IntervalsURLProtocolStub.handler = { _ in (200, body) }
			var arguments: [String: JSONValue] = ["activityId": .string("i1234567")]
			if let types { arguments["types"] = .array(types.map(JSONValue.string)) }
			let outcome = try await makeToolRuntime(
				intervals: client,
				ledger: Ledger(
					log: InMemoryRecordLog(), clock: clock,
					diagnostics: DiagnosticsLog(clock: clock)),
				clock: clock
			).execute(
				name: .intervalsFetchStreams, arguments: .object(arguments),
				scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
			).outcome
			guard case .result(let json) = outcome else {
				throw IntervalsError(code: "no_result", details: "\(outcome)")
			}
			return try #require(json.objectFields["data"])
		}
	}
}
