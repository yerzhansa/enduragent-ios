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
				let shown = try await readout(of: sample)
				#expect(
					ActivityProjectionKey.unaccounted(in: sample.npm, shown: shown) == [],
					"\(sample.name)")
			}
		}

		@Test func projectionKeyWithNoAccountIsReported() throws {
			let npm = try JSONValue.parse(
				#"[{"id":"i7","startDateLocal":"1998-06-13T08:00:00","movingTime":600,"kudos":3,"averageWatts":150},{"id":"i8","startDateLocal":"1998-06-12T08:00:00"},{"id":"i9","source":"STRAVA"}]"#
			)
			let shown = try JSONValue.parse(
				#"{"activities":[{"id":"i7","start":"1998-06-13T08:00:00","durationSeconds":601,"averagePower":150,"source":"UPLOAD"}],"hiddenByStrava":0}"#
			)
			#expect(
				ActivityProjectionKey.unaccounted(in: npm, shown: shown) == [
					"i7: key kudos has no account",
					"i7: movingTime is not shown as durationSeconds",
					"i7: source is shown",
					"2 rows are not listed and 0 are counted",
				])
		}

		private func readout(of sample: ActivityReadoutCase) async throws -> JSONValue {
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

enum ActivityProjectionKey: Equatable {
	case text(as: String)
	case number(as: String)
	case averageWattsNotInTheList
	case sourceReadByTheStravaRule

	static let rows: [String: ActivityProjectionKey] = [
		"startDateLocal": .text(as: "start"), "type": .text(as: "sport"),
		"name": .text(as: "name"), "movingTime": .number(as: "durationSeconds"),
		"distance": .number(as: "distance"), "icuTrainingLoad": .number(as: "load"),
		"icuIntensity": .number(as: "intensity"),
		"icuWeightedAvgWatts": .number(as: "weightedPower"),
		"averageHeartrate": .number(as: "averageHeartRate"),
		"maxHeartrate": .number(as: "maxHeartRate"), "icuFtp": .number(as: "ftp"),
		"totalElevationGain": .number(as: "elevationGain"),
		"averageWatts": .averageWattsNotInTheList, "source": .sourceReadByTheStravaRule,
	]

	static func unaccounted(in npm: JSONValue, shown phone: JSONValue) -> [String] {
		let listed = (phone.objectFields["activities"]?.arrayValue ?? []).map(\.objectFields)
		var problems: [String] = []
		var notListed = 0
		for row in (npm.arrayValue ?? []).map(\.objectFields) {
			let id = row["id"].flatMap { $0.stringValue ?? $0.intValue().map(String.init) }
			guard let id, let activity = listed.first(where: { $0["id"] == .string(id) }) else {
				notListed += 1
				continue
			}
			for (key, value) in row.sorted(by: { $0.key < $1.key }) where key != "id" {
				let shown: (name: String, supplied: Bool)
				switch rows[key] {
				case nil:
					problems.append("\(id): key \(key) has no account")
					continue
				case .text(let name)?:
					shown = (name, value.stringValue != nil)
				case .number(let name)?:
					shown = (name, value.numberValue != nil)
				case .averageWattsNotInTheList?, .sourceReadByTheStravaRule?:
					continue
				}
				let held = activity[shown.name]
				if held != value, held != nil || shown.supplied {
					problems.append("\(id): \(key) is not shown as \(shown.name)")
				}
			}
			if activity["source"] != nil { problems.append("\(id): source is shown") }
		}
		let counted = ["hiddenByStrava", "unreadable"].compactMap {
			phone.objectFields[$0]?.numberValue
		}.reduce(0, +)
		if Double(notListed) != counted {
			problems.append("\(notListed) rows are not listed and \(Int(counted)) are counted")
		}
		return problems
	}
}
