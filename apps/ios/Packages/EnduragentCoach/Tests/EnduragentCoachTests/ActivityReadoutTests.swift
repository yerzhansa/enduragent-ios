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

		@Test func everyKeyOfNpmsProjectionIsAccountedFor() throws {
			let projected = try ActivityReadoutCase.all().flatMap { npmKeys(of: $0.npm) }
			#expect(Set(projected).subtracting(ActivityReadoutCase.accountedNpmKeys) == [])
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

	static let accountedNpmKeys: Set<String> = [
		"id", "startDateLocal", "type", "name", "movingTime", "distance", "icuTrainingLoad",
		"icuIntensity", "icuWeightedAvgWatts", "averageHeartrate", "maxHeartrate", "icuFtp",
		"totalElevationGain", "averageWatts", "source",
	]

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

func npmKeys(of projection: JSONValue?) -> Set<String> {
	switch projection {
	case .array(let rows)?: rows.reduce(into: []) { $0.formUnion($1.objectFields.keys) }
	case let object?: Set(object.objectFields.keys)
	case nil: []
	}
}
