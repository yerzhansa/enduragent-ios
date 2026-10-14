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
				#expect(
					WellnessProjectionKey.unaccounted(in: sample.npm, shown: shown) == [],
					"\(sample.name)")
			}
		}

		@Test func projectionKeyWithNoAccountIsReported() throws {
			let npm = try JSONValue.parse(
				#"[{"id":"1998-06-13","ctl":55,"spO2":97},{"id":"1998-06-12","atl":40}]"#)
			let shown = try JSONValue.parse(
				#"{"days":[{"date":"1998-06-13","fitness":54,"sportInfo":[]}]}"#)
			#expect(
				WellnessProjectionKey.unaccounted(in: npm, shown: shown) == [
					"1998-06-13: ctl is not shown as fitness",
					"1998-06-13: key spO2 has no account",
					"1998-06-13: sportInfo is shown",
					"1998-06-12: the row is not shown",
				])
		}

		private func readout(of sample: WellnessReadoutCase) async throws -> JSONValue {
			let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
			let client = try IntervalsRESTClientTests().makeClient(clock: clock)
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

enum WellnessProjectionKey: Equatable {
	case shown(as: String)
	case sportInfoLeftOut

	static let rows: [String: WellnessProjectionKey] = [
		"id": .shown(as: "date"), "ctl": .shown(as: "fitness"), "atl": .shown(as: "fatigue"),
		"fatigue": .shown(as: "reportedFatigue"), "rampRate": .shown(as: "rampRate"),
		"weight": .shown(as: "weight"), "restingHR": .shown(as: "restingHeartRate"),
		"hrv": .shown(as: "hrv"), "sleepSecs": .shown(as: "sleepSeconds"),
		"sleepScore": .shown(as: "sleepScore"), "sleepQuality": .shown(as: "sleepQuality"),
		"readiness": .shown(as: "readiness"), "soreness": .shown(as: "soreness"),
		"stress": .shown(as: "stress"), "mood": .shown(as: "mood"),
		"motivation": .shown(as: "motivation"), "injury": .shown(as: "injury"),
		"sportInfo": .sportInfoLeftOut,
	]

	static func unaccounted(in npm: JSONValue, shown phone: JSONValue) -> [String] {
		let days = (phone.objectFields["days"]?.arrayValue ?? []).map(\.objectFields)
		var problems: [String] = []
		for row in (npm.arrayValue ?? []).map(\.objectFields) {
			let id = row["id"]?.stringValue
			let label = id ?? "row without a date"
			let day = days.first { $0["date"] == row["id"] }
			for (key, value) in row.sorted(by: { $0.key < $1.key }) {
				guard let rule = rows[key] else {
					problems.append("\(label): key \(key) has no account")
					continue
				}
				guard let day else { continue }
				switch rule {
				case .shown(let name):
					let held = day[name]
					if held != value, held != nil || value.numberValue != nil {
						problems.append("\(label): \(key) is not shown as \(name)")
					}
				case .sportInfoLeftOut:
					break
				}
			}
			if let day {
				if day["sportInfo"] != nil { problems.append("\(label): sportInfo is shown") }
			} else if id.flatMap(CivilDate.init(rawValue:)) != nil {
				problems.append("\(label): the row is not shown")
			}
		}
		return problems
	}
}
