import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests.ActivityReadoutTests {
	@Test func activityDetailShowsTheExpectedResultForEveryCase() async throws {
		let cases = try ActivityDetailReadoutCase.all()
		#expect(cases.count == 17)
		for sample in cases {
			let shown = try await detailReadout(of: sample)
			#expect(shown == sample.phone, "\(sample.name): \(canonicalJSON(shown))")
		}
	}

	@Test func everyKeyNpmPassesIsAccountedFor() throws {
		let passed = try ActivityDetailReadoutCase.all().compactMap { sample in
			sample.phone.objectFields["activity"].flatMap { _ in sample.npm.objectFields["passes"] }
		}
		#expect(passed.count == 8)
		let keys = passed.flatMap { npmKeys(of: $0) }
		#expect(Set(keys).subtracting(ActivityDetailReadoutCase.accountedNpmKeys) == [])
	}

	private func detailReadout(of sample: ActivityDetailReadoutCase) async throws -> JSONValue {
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let client = try IntervalsRESTClientTests().makeClient(clock: clock)
		let status = sample.status
		let body = Data(canonicalJSON(sample.response).utf8)
		IntervalsURLProtocolStub.handler = { _ in (status, body) }
		let outcome = try await makeToolRuntime(
			intervals: client,
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock,
				diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		).execute(
			name: .intervalsFetchActivity, arguments: sample.arguments,
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		).outcome
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "no_result", details: "\(outcome)")
		}
		return try #require(json.objectFields["data"])
	}
}

struct ActivityDetailReadoutCase: Sendable {
	let name: String
	let arguments: JSONValue
	let status: Int
	let response: JSONValue
	let npm: JSONValue
	let phone: JSONValue

	static let accountedNpmKeys: Set<String> = ActivityReadoutCase.accountedNpmKeys.union([
		"description", "trainer", "icuAverageWatts", "icuRpe", "feel", "averageCadence",
		"averageSpeed", "maxSpeed", "calories", "icuJoules", "icuVariabilityIndex",
		"icuEfficiencyFactor", "decoupling", "icuZoneTimes", "icuHrZoneTimes", "icuIntervals",
		"elapsedTime", "pairedEventId", "icuAthleteId", "externalId", "deviceName", "icuWeight",
		"timezone", "streamTypes", "gear", "icuGroups",
	])

	static func all() throws -> [ActivityDetailReadoutCase] {
		let text = try #require(
			String(data: try fixtureData("readout-activity"), encoding: .utf8))
		return try #require(try JSONValue.parse(text).arrayValue).map { entry in
			let fields = entry.objectFields
			return ActivityDetailReadoutCase(
				name: try #require(fields["name"]?.stringValue),
				arguments: try #require(fields["arguments"]),
				status: try #require(fields["status"]?.intValue()),
				response: try #require(fields["response"]),
				npm: try #require(fields["npm"]),
				phone: try #require(fields["phone"]))
		}
	}
}
