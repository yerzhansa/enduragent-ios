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

	@Test func everyKeyNpmPassesIsAccountedFor() async throws {
		var compared = 0
		for sample in try ActivityDetailReadoutCase.all() {
			let shown = try await detailReadout(of: sample).objectFields
			guard var activity = shown["activity"]?.objectFields,
				let passed = sample.npm.objectFields["passes"]
			else { continue }
			compared += 1
			activity["laps"] = shown["laps"]
			let problems = NpmProjectionAudit.problems(
				in: [(ActivityDetailReadoutCase.npmProjection, passed.objectFields)],
				shown: activity)
			#expect(problems == [], "\(sample.name)")
		}
		#expect(compared == 8)
	}

	private func detailReadout(of sample: ActivityDetailReadoutCase) async throws -> JSONValue {
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let client = try IntervalsRESTClientTests().makeClient()
		let status = sample.status
		let body = Data(canonicalJSON(sample.response).utf8)
		IntervalsURLProtocolStub.handler = { _ in (status, body) }
		let outcome = try await makeOfferedTools(
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

	static let npmProjection = NpmProjectionAudit(
		ActivityReadoutCase.npmKeys.merging(detailKeys) { $1 })

	private static let outsideTheDetail = NpmKey.leftOut("it is outside the detail-only fields")

	private static let detailKeys: [String: NpmKey] = [
		"description": .shown(as: "notes", .text),
		"trainer": .shown(as: "indoor", .flag),
		"icuAverageWatts": .measured(ActivityField.averagePower),
		"icuRpe": .measured(ActivityDetailField.perceivedExertion),
		"feel": .measured(ActivityDetailField.feel),
		"averageCadence": .measured(ActivityDetailField.averageCadence),
		"averageSpeed": .measured(ActivityDetailField.averageSpeed),
		"maxSpeed": .measured(ActivityDetailField.maxSpeed),
		"calories": .measured(ActivityDetailField.calories),
		"icuJoules": .measured(ActivityDetailField.work),
		"icuVariabilityIndex": .measured(ActivityDetailField.variabilityIndex),
		"icuEfficiencyFactor": .measured(ActivityDetailField.efficiencyFactor),
		"decoupling": .measured(ActivityDetailField.decoupling),
		"icuZoneTimes": .shown(
			as: "powerZoneSeconds", .list(renaming: ["id": "zone", "secs": "seconds"])),
		"icuHrZoneTimes": .shown(as: "heartRateZoneSeconds", .list(renaming: [:])),
		"icuIntervals": .shown(as: "laps", .count),
		"elapsedTime": .leftOut("only the Strava rule reads it"),
		"pairedEventId": outsideTheDetail,
		"icuAthleteId": outsideTheDetail,
		"externalId": outsideTheDetail,
		"deviceName": outsideTheDetail,
		"icuWeight": outsideTheDetail,
		"timezone": outsideTheDetail,
		"streamTypes": outsideTheDetail,
		"gear": outsideTheDetail,
		"icuGroups": outsideTheDetail,
	]

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
