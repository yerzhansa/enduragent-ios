import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct WellnessReadoutTests {
		@Test func wellnessToolShowsTheExpectedResultForEveryCase() async throws {
			let cases = try WellnessReadoutCase.all()
			#expect(cases.count == 8)
			for sample in cases {
				let shown = try await readout(of: sample)
				#expect(shown == sample.phone, "\(sample.name): \(canonicalJSON(shown))")
			}
		}

		@Test func everyKeyOfNpmsProjectionIsAccountedFor() throws {
			let projected = try WellnessReadoutCase.all().flatMap { npmKeys(of: $0.npm) }
			#expect(Set(projected).subtracting(WellnessReadoutCase.accountedNpmKeys) == [])
		}

		private func readout(of sample: WellnessReadoutCase) async throws -> JSONValue {
			let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
			let client = try IntervalsRESTClientTests().makeClient(clock: clock)
			let body = Data(canonicalJSON(sample.response).utf8)
			IntervalsURLProtocolStub.handler = { _ in (200, body) }
			let outcome = try await makeToolRuntime(
				intervals: client,
				ledger: Ledger(
					log: InMemoryRecordLog(), clock: clock,
					diagnostics: DiagnosticsLog(clock: clock)),
				clock: clock
			).execute(
				name: .intervalsFetchWellness, arguments: sample.arguments,
				scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
			).outcome
			guard case .result(let json) = outcome else {
				throw IntervalsError(code: "no_result", details: "\(outcome)")
			}
			return try #require(json.objectFields["data"])
		}
	}
}

struct WellnessReadoutCase: Sendable {
	let name: String
	let arguments: JSONValue
	let response: JSONValue
	let npm: JSONValue
	let phone: JSONValue

	static let accountedNpmKeys: Set<String> = [
		"id", "ctl", "atl", "fatigue", "rampRate", "weight", "restingHR", "hrv", "sleepSecs",
		"sleepScore", "sleepQuality", "readiness", "soreness", "stress", "mood", "motivation",
		"injury", "sportInfo",
	]

	static func all() throws -> [WellnessReadoutCase] {
		let text = try #require(String(data: try fixtureData("readout-wellness"), encoding: .utf8))
		return try #require(try JSONValue.parse(text).arrayValue).map { entry in
			let fields = entry.objectFields
			return WellnessReadoutCase(
				name: try #require(fields["name"]?.stringValue),
				arguments: try #require(fields["arguments"]),
				response: try #require(fields["response"]),
				npm: try #require(fields["npm"]),
				phone: try #require(fields["phone"]))
		}
	}
}
