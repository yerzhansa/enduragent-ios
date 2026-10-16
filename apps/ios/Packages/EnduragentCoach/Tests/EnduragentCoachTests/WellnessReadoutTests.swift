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

		@Test func everyKeyOfNpmsProjectionIsAccountedFor() async throws {
			for sample in try WellnessReadoutCase.all() {
				let shown = try await readout(of: sample)
				let audit = WellnessReadoutCase.npmProjection.rows(
					sample.npm, shown: shown.objectFields["days"]?.arrayValue ?? [])
				#expect(audit.problems == [], "\(sample.name)")
				let dated = audit.unmatched.compactMap {
					$0["id"]?.stringValue.flatMap(CivilDate.init(rawValue:))
				}
				#expect(dated == [], "\(sample.name)")
			}
		}

		private func readout(of sample: WellnessReadoutCase) async throws -> JSONValue {
			let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
			let client = try IntervalsRESTClientTests().makeClient()
			let body = Data(canonicalJSON(sample.response).utf8)
			IntervalsURLProtocolStub.handler = { _ in (200, body) }
			let outcome = try await makeOfferedTools(
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

	static let npmProjection = NpmProjectionAudit(
		[
			"id": .shown(as: "date", .text),
			"ctl": .measured(WellnessField.fitness),
			"atl": .measured(WellnessField.fatigue),
			"fatigue": .measured(WellnessField.reportedFatigue),
			"rampRate": .measured(WellnessField.rampRate),
			"weight": .measured(WellnessField.weight),
			"restingHR": .measured(WellnessField.restingHeartRate),
			"hrv": .measured(WellnessField.hrv),
			"sleepSecs": .measured(WellnessField.sleepSeconds),
			"sleepScore": .measured(WellnessField.sleepScore),
			"sleepQuality": .measured(WellnessField.sleepQuality),
			"readiness": .measured(WellnessField.readiness),
			"soreness": .measured(WellnessField.soreness),
			"stress": .measured(WellnessField.stress),
			"mood": .measured(WellnessField.mood),
			"motivation": .measured(WellnessField.motivation),
			"injury": .measured(WellnessField.injury),
			"sportInfo": .leftOut("the phone coaches cycling only"),
		], phoneOnly: ["form"])

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
