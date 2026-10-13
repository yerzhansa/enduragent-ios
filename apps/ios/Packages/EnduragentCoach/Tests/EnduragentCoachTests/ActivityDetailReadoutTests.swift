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

	@Test func everyFieldNpmPassesIsShownUnderItsKeyOrDroppedByName() async throws {
		var compared = 0
		for sample in try ActivityDetailReadoutCase.all() {
			guard let passed = sample.npm.objectFields["passes"],
				sample.phone.objectFields["activity"] != nil
			else { continue }
			compared += 1
			#expect(
				ActivityDetailKey.unaccounted(in: passed, shown: sample.phone) == [],
				"\(sample.name)")
		}
		#expect(compared == 8)
	}

	@Test func detailFieldWithNoAccountIsReported() throws {
		let npm = try JSONValue.parse(
			#"{"id":"i7","startDateLocal":"1998-06-13T08:00:00","movingTime":600,"icuRpe":6,"trainer":true,"kudos":3,"pairedEventId":42}"#
		)
		let shown = try JSONValue.parse(
			#"{"activity":{"id":"i7","start":"1998-06-13T08:00:00","durationSeconds":601,"rpe":6,"pairedEventId":42}}"#
		)
		#expect(
			ActivityDetailKey.unaccounted(in: npm, shown: shown) == [
				"key kudos has no account",
				"movingTime is not shown as durationSeconds",
				"trainer is not shown as indoor",
				"pairedEventId is shown and no source field is shown under that key",
			])
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

enum ActivityDetailKey: Equatable {
	case identifier
	case text(as: String)
	case number(as: String)
	case flag(as: String)
	case list(as: String)
	case laps
	case dropped

	static let fields: [String: ActivityDetailKey] = [
		"id": .identifier, "startDateLocal": .text(as: "start"), "type": .text(as: "sport"),
		"name": .text(as: "name"), "description": .text(as: "notes"),
		"trainer": .flag(as: "indoor"), "movingTime": .number(as: "durationSeconds"),
		"distance": .number(as: "distance"), "icuTrainingLoad": .number(as: "load"),
		"icuIntensity": .number(as: "intensity"),
		"icuAverageWatts": .number(as: "averagePower"),
		"icuWeightedAvgWatts": .number(as: "weightedPower"),
		"averageHeartrate": .number(as: "averageHeartRate"),
		"maxHeartrate": .number(as: "maxHeartRate"), "icuFtp": .number(as: "ftp"),
		"totalElevationGain": .number(as: "elevationGain"), "icuRpe": .number(as: "rpe"),
		"feel": .number(as: "feel"), "averageCadence": .number(as: "averageCadence"),
		"averageSpeed": .number(as: "averageSpeed"), "maxSpeed": .number(as: "maxSpeed"),
		"calories": .number(as: "calories"), "icuJoules": .number(as: "work"),
		"icuVariabilityIndex": .number(as: "variabilityIndex"),
		"icuEfficiencyFactor": .number(as: "efficiencyFactor"),
		"decoupling": .number(as: "decoupling"),
		"icuZoneTimes": .list(as: "powerZoneSeconds"),
		"icuHrZoneTimes": .list(as: "heartRateZoneSeconds"), "icuIntervals": .laps,
		"source": .dropped, "elapsedTime": .dropped, "pairedEventId": .dropped,
		"icuAthleteId": .dropped, "externalId": .dropped, "deviceName": .dropped,
		"averageWatts": .dropped, "icuWeight": .dropped, "timezone": .dropped,
		"streamTypes": .dropped, "gear": .dropped, "icuGroups": .dropped,
	]

	static func unaccounted(in npm: JSONValue, shown phone: JSONValue) -> [String] {
		let activity = phone.objectFields["activity"]?.objectFields ?? [:]
		var problems: [String] = []
		var explained: Set<String> = ["id"]
		for (key, value) in npm.objectFields.sorted(by: { $0.key < $1.key }) {
			let shown: (name: String, supplied: Bool)
			switch fields[key] {
			case nil:
				problems.append("key \(key) has no account")
				continue
			case .dropped?:
				continue
			case .identifier?:
				let id = value.stringValue ?? value.intValue().map(String.init)
				if activity["id"]?.stringValue != id { problems.append("id is not shown as sent") }
				continue
			case .laps?:
				let listed = phone.objectFields["laps"]?.arrayValue?.count
				if listed != value.arrayValue?.count {
					problems.append("icuIntervals is not shown as laps")
				}
				continue
			case .list(let name)?:
				explained.insert(name)
				let listed = activity[name]?.arrayValue?.count ?? 0
				if listed != value.arrayValue?.count ?? 0 {
					problems.append("\(key) is not shown as \(name)")
				}
				continue
			case .text(let name)?:
				shown = (name, value.stringValue != nil)
			case .number(let name)?:
				shown = (name, value.numberValue != nil)
			case .flag(let name)?:
				shown = (name, value.boolValue != nil)
			}
			explained.insert(shown.name)
			let held = activity[shown.name]
			if held != value, held != nil || shown.supplied {
				problems.append("\(key) is not shown as \(shown.name)")
			}
		}
		for name in activity.keys.sorted() where !explained.contains(name) {
			problems.append("\(name) is shown and no source field is shown under that key")
		}
		return problems
	}
}
