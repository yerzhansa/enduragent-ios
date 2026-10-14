import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct ActivityReadoutTests {
		@Test func activityListShowsTheExpectedResultForEveryCase() async throws {
			let cases = try ActivityReadoutCase.all()
			#expect(cases.count == 9)
			for sample in cases {
				let shown = try await readout(of: sample)
				#expect(shown == sample.phone, "\(sample.name): \(canonicalJSON(shown))")
			}
		}

		@Test func weekSentNewestFirstIsListedInNpmsOrder() async throws {
			let week = try #require(
				try ActivityReadoutCase.all().first { $0.name == "a week, sent newest first" })
			let shown = try #require(
				try await readout(of: week).objectFields["activities"]?.arrayValue
			).map { $0.objectFields["id"] }
			let npm = try #require(week.npm.arrayValue).map { $0.objectFields["id"] }
			#expect(shown.count == 9)
			#expect(shown == npm.filter(shown.contains))
		}

		@Test func everyKeyOfNpmsProjectionIsAccountedFor() async throws {
			for sample in try ActivityReadoutCase.all() {
				let shown = try await readout(of: sample).objectFields
				let audit = ActivityReadoutCase.npmProjection.rows(
					sample.npm, shown: shown["activities"]?.arrayValue ?? [])
				#expect(audit.problems == [], "\(sample.name)")
				let counted = ["hiddenByStrava", "unreadable"].compactMap { shown[$0]?.intValue() }
				#expect(audit.unmatched.count == counted.reduce(0, +), "\(sample.name)")
			}
		}

		private func readout(of sample: ActivityReadoutCase) async throws -> JSONValue {
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
				name: .intervalsFetchActivities, arguments: sample.arguments,
				scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
			).outcome
			guard case .result(let json) = outcome else {
				throw IntervalsError(code: "no_result", details: "\(outcome)")
			}
			return try #require(json.objectFields["data"])
		}
	}
}

struct ActivityReadoutCase: Sendable {
	let name: String
	let arguments: JSONValue
	let response: JSONValue
	let npm: JSONValue
	let phone: JSONValue

	static let npmKeys: [String: NpmKey] = [
		"id": .shown(as: "id", .identifier),
		"startDateLocal": .shown(as: "start", .text),
		"type": .shown(as: "sport", .text),
		"name": .shown(as: "name", .text),
		"movingTime": .measured(ActivityField.duration),
		"distance": .measured(ActivityField.distance),
		"icuTrainingLoad": .measured(ActivityField.load),
		"icuIntensity": .measured(ActivityField.intensity),
		"icuWeightedAvgWatts": .measured(ActivityField.weightedPower),
		"averageHeartrate": .measured(ActivityField.averageHeartRate),
		"maxHeartrate": .measured(ActivityField.maxHeartRate),
		"icuFtp": .measured(ActivityField.ftp),
		"totalElevationGain": .measured(ActivityField.elevationGain),
		"averageWatts": .leftOut("the phone shows icu_average_watts as the average power"),
		"source": .leftOut("only the Strava rule reads it"),
	]

	static let npmProjection = NpmProjectionAudit(
		npmKeys, phoneOnly: [ActivityField.averagePower.rawValue])

	static func all() throws -> [ActivityReadoutCase] {
		let text = try #require(
			String(data: try fixtureData("readout-activities"), encoding: .utf8))
		return try #require(try JSONValue.parse(text).arrayValue).map { entry in
			let fields = entry.objectFields
			return ActivityReadoutCase(
				name: try #require(fields["name"]?.stringValue),
				arguments: try #require(fields["arguments"]),
				response: try #require(fields["response"]),
				npm: try #require(fields["npm"]),
				phone: try #require(fields["phone"]))
		}
	}
}
