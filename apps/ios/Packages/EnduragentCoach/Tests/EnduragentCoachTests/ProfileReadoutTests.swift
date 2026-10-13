import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct ProfileReadoutTests {
		@Test func profileToolShowsTheExpectedResultForEveryCase() async throws {
			let cases = try ProfileReadoutCase.all()
			#expect(cases.count == 11)
			for sample in cases {
				let shown = try await readout(of: sample.response, now: sample.noon)
				#expect(shown == sample.phone, "\(sample.name): \(canonicalJSON(shown))")
			}
		}

		@Test func everyKeyOfNpmsProjectionIsAccountedFor() async throws {
			for sample in try ProfileReadoutCase.all() {
				let shown = try await readout(of: sample.response, now: sample.noon)
				#expect(
					ProjectionKey.unaccounted(in: sample.npm, shown: shown) == [],
					"\(sample.name)")
			}
		}

		@Test func projectionKeyWithNoAccountIsReported() throws {
			let npm = try JSONValue.parse(
				#"{"id":"i1001","height":1.7,"sportSettings":[{"types":["Run"],"cadence":90}]}"#)
			let shown = try JSONValue.parse(#"{"id":"i1001"}"#)
			#expect(
				ProjectionKey.unaccounted(in: npm, shown: shown) == [
					"settings row key cadence has no account", "athlete key height has no account",
				])
		}

		@Test(arguments: [("1998-06-13T23:30:00+02:00", 27.0), ("1998-06-14T00:30:00+02:00", 28.0)])
		func ageIsWholeYearsOnThePhonesToday(now: String, years: Double) async throws {
			let athlete = try JSONValue.parse(
				#"{"id":"i1001","name":"Ada","icu_date_of_birth":"1970-06-14","sportSettings":[]}"#)
			let shown = try await readout(of: athlete, now: now)
			#expect(shown.objectFields["ageYears"] == .number(years))
		}

		@Test func dateOfBirthReachesNoPromptNoToolResultAndNoDiagnosticsEntry() async throws {
			let transport = FakeModelTransport()
			transport.respond = ScriptedReply.sequence(
				[
					.toolCall(name: "intervals_fetch_athlete", arguments: "{}"),
					.finish(reason: .toolCalls),
					.text("You are 27."),
					.finish(reason: .stop),
				], for: .chat, otherwise: transport.respond)
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let coach = await makeCoach(
				transport: transport,
				intervals: try IntervalsRESTClientTests().makeClient(clock: clock),
				store: InMemoryRecordLog(), clock: clock)

			let settled = try await coach.sendAndSettle("How old am I?")

			#expect(replyText(settled) == "You are 27.")
			let result = try #require(
				transport.requests.last?.messages.last { $0.role == .tool }?.content)
			#expect(result.contains("ageYears"))
			let sent = transport.requests.flatMap(\.messages).map(\.content).joined(separator: "\n")
			#expect(!sent.contains("1970"))
			let recorded = coach.diagnostics.entries.map { String(describing: $0.event) }.joined()
			#expect(!recorded.contains("1970"))
		}

		private func readout(of response: JSONValue, now: String) async throws -> JSONValue {
			let clock = FixedClock(now: now, timeZone: "Europe/Amsterdam")
			let client = try IntervalsRESTClientTests().makeClient(clock: clock)
			let body = Data(canonicalJSON(response).utf8)
			IntervalsURLProtocolStub.handler = { _ in (200, body) }
			let outcome = try await makeToolRuntime(
				intervals: client,
				ledger: Ledger(
					log: InMemoryRecordLog(), clock: clock,
					diagnostics: DiagnosticsLog(clock: clock)),
				clock: clock
			).execute(
				name: .intervalsFetchAthlete, arguments: .object([:]),
				scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
			).outcome
			guard case .result(let json) = outcome else {
				throw IntervalsError(code: "no_result", details: "\(outcome)")
			}
			return try #require(json.objectFields["data"])
		}
	}
}

struct ProfileReadoutCase: Sendable {
	let name: String
	let noon: String
	let response: JSONValue
	let npm: JSONValue
	let phone: JSONValue

	static func all() throws -> [ProfileReadoutCase] {
		let text = try #require(String(data: try fixtureData("readout-profile"), encoding: .utf8))
		return try #require(try JSONValue.parse(text).arrayValue).map { entry in
			let fields = entry.objectFields
			return ProfileReadoutCase(
				name: try #require(fields["name"]?.stringValue),
				noon: "\(try #require(fields["today"]?.stringValue))T12:00:00+02:00",
				response: try #require(fields["response"]),
				npm: try #require(fields["npm"]),
				phone: try #require(fields["phone"]))
		}
	}
}

enum ProjectionKey: Equatable {
	case same(String)
	case source(of: String)
	case zoneBounds(String)
	case zoneNames(String)
	case replacedByAge
	case paceLeftOut
	case settingsRows

	static let athlete: [String: ProjectionKey] = [
		"id": .same("id"), "name": .same("name"), "sex": .same("sex"),
		"icuFtp": .source(of: "ftp"), "icuLthr": .source(of: "lthr"),
		"icuMaxHr": .source(of: "maxHeartRate"), "icuRestingHr": .source(of: "restingHeartRate"),
		"icuWeight": .source(of: "weight"), "weight": .source(of: "weight"),
		"icuDateOfBirth": .replacedByAge, "sportSettings": .settingsRows,
	]

	static let settings: [String: ProjectionKey] = [
		"types": .same("sports"), "ftp": .source(of: "ftp"), "lthr": .source(of: "lthr"),
		"maxHr": .source(of: "maxHeartRate"), "restingHr": .source(of: "restingHeartRate"),
		"weight": .source(of: "weight"), "indoorFtp": .same("indoorFtp"),
		"wPrime": .same("wPrime"), "pMax": .same("maxPower"),
		"sweetSpotMin": .same("sweetSpotMin"), "sweetSpotMax": .same("sweetSpotMax"),
		"powerZones": .zoneBounds("powerZones"), "powerZoneNames": .zoneNames("powerZones"),
		"hrZones": .zoneBounds("heartRateZones"), "hrZoneNames": .zoneNames("heartRateZones"),
		"thresholdPace": .paceLeftOut, "paceUnits": .paceLeftOut,
	]

	static func unaccounted(in npm: JSONValue, shown phone: JSONValue) -> [String] {
		let shown = phone.objectFields
		let rows = (npm.objectFields["sportSettings"]?.arrayValue ?? []).map(\.objectFields)
		let used = rows.first { $0["types"] != nil && $0["types"] == shown["sports"] } ?? [:]
		var problems = rows.flatMap(\.keys).filter { settings[$0] == nil }.sorted().map {
			"settings row key \($0) has no account"
		}
		var entries: [(key: String, value: JSONValue, rule: ProjectionKey)] = []
		for (key, value) in npm.objectFields.sorted(by: { $0.key < $1.key }) {
			guard let rule = athlete[key] else {
				problems.append("athlete key \(key) has no account")
				continue
			}
			entries.append((key, value, rule))
		}
		for (key, value) in used.sorted(by: { $0.key < $1.key }) {
			if let rule = settings[key] { entries.append((key, value, rule)) }
		}
		for entry in entries {
			let sources = entries.filter { $0.rule == entry.rule }.map(\.value)
			if !entry.rule.holds(entry.value, sources: sources, shown: shown, phone: phone) {
				problems.append("\(entry.key) is not shown as \(entry.rule)")
			}
		}
		return problems
	}

	private func holds(
		_ value: JSONValue, sources: [JSONValue], shown: [String: JSONValue], phone: JSONValue
	) -> Bool {
		switch self {
		case .same(let key):
			return shown[key] == value
		case .source(let key):
			guard let held = shown[key] else {
				return sources.contains { $0.numberValue == nil }
			}
			return sources.contains(held)
		case .zoneBounds(let key):
			let bounds = value.arrayValue ?? []
			guard let ladder = shown[key]?.arrayValue else {
				return bounds.isEmpty || bounds.contains { $0.numberValue == nil }
			}
			return ladder.map { $0.objectFields["upTo"] } == bounds
		case .zoneNames(let key):
			let names = value.arrayValue ?? []
			return (shown[key]?.arrayValue ?? []).enumerated().allSatisfy { index, zone in
				zone.objectFields["name"] == (index < names.count ? names[index] : nil)
			}
		case .replacedByAge:
			return value.stringValue.map { !canonicalJSON(phone).contains($0) } ?? false
		case .paceLeftOut, .settingsRows:
			return true
		}
	}
}
