import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct StreamRejectionTests {
		static let unknown = "enduragent_unknown_channel"
		static let requestLimit = 10
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		private let asked = AskedTypes()

		@Test func unknownChannelIsNamedUnknownAndTheKnownOnesKeepTheirNumbers() async throws {
			let shown = try await readout(
				types: ["watts", Self.unknown, "heartrate", "temp"], rejecting: [Self.unknown])
			#expect(
				shown
					== (try JSONValue.parse(
						#"{"sampleCount":10,"channels":{"watts":{"min":0,"max":400,"mean":214.4},"heartrate":{"min":140,"max":160,"mean":151.3}},"unanswered":["temp"],"unknown":["enduragent_unknown_channel"]}"#
					)), "\(canonicalJSON(shown))")
			#expect(asked.all == ["watts,\(Self.unknown),heartrate,temp", "watts,heartrate,temp"])
		}

		@Test func readWhereEveryChannelIsUnknownAnswersNothingAndIsNotAFailure() async throws {
			let shown = try await readout(
				types: ["enduragent_unknown_a", "enduragent_unknown_b", "enduragent_unknown_a"],
				rejecting: ["enduragent_unknown_a", "enduragent_unknown_b"])
			#expect(
				shown
					== (try JSONValue.parse(
						#"{"sampleCount":0,"channels":{},"unknown":["enduragent_unknown_a","enduragent_unknown_b"]}"#
					)), "\(canonicalJSON(shown))")
			#expect(
				asked.all == [
					"enduragent_unknown_a,enduragent_unknown_b,enduragent_unknown_a",
					"enduragent_unknown_b",
				])
		}

		@Test(arguments: [
			(401, #"{"status":401,"error":"Unauthorized"}"#),
			(403, #"{"status":403,"error":"Access denied"}"#),
			(404, #"{"status":404,"error":"Activity i1234567 not found"}"#),
			(400, #"{"status":400,"error":"Invalid stream type [watts]"}"#),
			(429, #"{"status":429,"error":"Too many requests"}"#),
			(500, #"{"status":500,"error":"Invalid stream type [watts]"}"#),
			(503, ""),
			(422, #"{"status":422,"error":"Invalid activity"}"#),
			(422, #"{"status":422,"error":"Invalid activity [watts]"}"#),
			(422, #"{"status":422,"error":"Invalid stream kind [watts]"}"#),
			(422, #"{"status":422,"error":"Invalid stream type [velocity]"}"#),
			(422, #"{"status":422,"message":"Invalid stream type [watts]"}"#),
			(422, "Invalid stream type [watts]"),
		])
		func everyOtherRejectionStillFailsTheRead(status: Int, body: String) async throws {
			let client = try serving { _ in (status, Data(body.utf8)) }
			await #expect(
				throws: IntervalsError(code: "http", details: "status \(status)", status: status)
			) {
				_ = try await client.streams(
					of: try #require(ActivityID(rawValue: "i1234567")),
					channels: StreamChannels(requested: ["watts", "heartrate"]))
			}
			#expect(asked.all == ["watts,heartrate"])
		}

		@Test func failureAfterAnUnknownChannelWasDroppedStillFailsTheRead() async throws {
			let rejection = try fixtureData("intervals-streams-invalid-type")
			let client = try serving { types in
				types.contains(Self.unknown) ? (422, rejection) : (503, Data())
			}
			await #expect(throws: IntervalsError(code: "http", details: "status 503", status: 503))
			{
				_ = try await client.streams(
					of: try #require(ActivityID(rawValue: "i1234567")),
					channels: StreamChannels(requested: [Self.unknown, "watts"]))
			}
			#expect(asked.all == ["\(Self.unknown),watts", "watts"])
		}

		@Test(arguments: [true, false])
		func networkFailureStillFailsTheRead(afterAnUnknownChannel: Bool) async throws {
			let rejection = try fixtureData("intervals-streams-invalid-type")
			let client = try serving { types in
				if afterAnUnknownChannel, types.contains(Self.unknown) { return (422, rejection) }
				throw URLError(.notConnectedToInternet)
			}
			let channels = afterAnUnknownChannel ? ["watts", Self.unknown] : ["watts"]
			await #expect(
				throws: IntervalsError(
					code: "network", details: "intervals.icu could not be reached (URLError -1009)."
				)
			) {
				_ = try await client.streams(
					of: try #require(ActivityID(rawValue: "i1234567")),
					channels: StreamChannels(requested: channels))
			}
			#expect(asked.all.last == "watts")
		}

		@Test func eachUnknownNameCostsOneRequestAndTheReadEndsWithTheKnownOnes() async throws {
			let shown = try await readout(
				types: ["u1", "watts", "u2", "u1", "u2"], rejecting: ["u1", "u2"])
			#expect(shown.objectFields["unknown"] == .array(["u1", "u2"].map(JSONValue.string)))
			#expect(shown.objectFields["unanswered"] == nil)
			#expect(shown.objectFields["channels"]?.objectFields.keys.sorted() == ["watts"])
			#expect(asked.all == ["u1,watts,u2,u1,u2", "watts,u2,u2", "watts"])
		}

		@Test func cappedReadNamesTheChannelsItDidNotReadAsUnread() async throws {
			let invented = (1...12).map { "u\($0)" }
			let shown = try await readout(
				types: invented + ["watts", "temp"], rejecting: Set(invented))
			#expect(
				shown
					== .object([
						"sampleCount": .number(0), "channels": .object([:]),
						"unknown": .array(invented.prefix(3).map(JSONValue.string)),
						"unread": .array(
							(invented.dropFirst(3) + ["watts", "temp"]).map(JSONValue.string)),
					]), "\(canonicalJSON(shown))")
			#expect(asked.all.count == 3)
		}

		@Test func rejectionNamingAChannelNoLongerAskedForEndsTheRead() async throws {
			let rejection = try fixtureData("intervals-streams-invalid-type")
			let client = try serving { _ in (422, rejection) }
			await #expect(throws: IntervalsError(code: "http", details: "status 422", status: 422))
			{
				_ = try await client.streams(
					of: try #require(ActivityID(rawValue: "i1234567")),
					channels: StreamChannels(requested: ["watts", Self.unknown]))
			}
			#expect(asked.all == ["watts,\(Self.unknown)", "watts"])
		}

		private func serving(_ answer: @escaping @Sendable (String) throws -> (Int, Data)) throws
			-> IntervalsRESTClient
		{
			let client = try IntervalsRESTClientTests().makeClient()
			let asked = asked
			IntervalsURLProtocolStub.handler = { request in
				let url = try #require(request.url)
				let types = try #require(
					URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
						.first { $0.name == "types" }?.value)
				asked.record(types)
				guard asked.all.count <= Self.requestLimit else {
					throw URLError(.cannotLoadFromNetwork)
				}
				return try answer(types)
			}
			return client
		}

		private func readout(types: [String], rejecting unknown: Set<String>) async throws
			-> JSONValue
		{
			let rejection = String(
				decoding: try fixtureData("intervals-streams-invalid-type"), as: UTF8.self)
			let recorded = try #require(
				try JSONValue.parse(
					String(decoding: try fixtureData("intervals-streams"), as: UTF8.self)
				)
				.arrayValue)
			let client = try serving { types in
				let names = types.split(separator: ",", omittingEmptySubsequences: false).map(
					String.init)
				if let first = names.first(where: unknown.contains) {
					return (
						422,
						Data(rejection.replacingOccurrences(of: Self.unknown, with: first).utf8)
					)
				}
				let sent = recorded.filter {
					names.contains($0.objectFields["type"]?.stringValue ?? "")
				}
				return (200, Data(canonicalJSON(.array(sent)).utf8))
			}
			let outcome = try await makeOfferedTools(
				intervals: client,
				ledger: Ledger(
					log: InMemoryRecordLog(), clock: clock,
					diagnostics: DiagnosticsLog(clock: clock)),
				clock: clock
			).execute(
				name: .intervalsFetchStreams,
				arguments: .object([
					"activityId": .string("i1234567"), "types": .array(types.map(JSONValue.string)),
				]),
				scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
			).outcome
			guard case .result(let json) = outcome else {
				throw IntervalsError(code: "no_result", details: "\(outcome)")
			}
			return try #require(json.objectFields["data"])
		}
	}
}

private final class AskedTypes: Sendable {
	private let queries = Mutex<[String]>([])

	var all: [String] { queries.withLock { $0 } }

	func record(_ types: String) {
		queries.withLock { $0.append(types) }
	}
}
