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
				let shown = try await readout(of: sample.response, now: sample.noon).objectFields
				var athlete = sample.npm.objectFields
				let rows = (athlete.removeValue(forKey: "sportSettings")?.arrayValue ?? [])
					.map(\.objectFields)
				let cycling = rows.first { row in
					(row["types"]?.arrayValue ?? []).contains {
						$0.stringValue.map(IntervalsPolicy.cyclingSports.contains) ?? false
					}
				}
				let read = cycling ?? rows.first ?? [:]
				let problems = NpmProjectionAudit.problems(
					in: [
						(ProfileReadoutCase.athleteProjection, athlete),
						(ProfileReadoutCase.settingsProjection, read),
					], shown: shown)
				let unread = rows.filter { $0 != read }.flatMap {
					ProfileReadoutCase.settingsProjection.unaccounted(in: $0)
				}
				#expect(problems + unread == [], "\(sample.name)")
			}
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

	static let athleteProjection = NpmProjectionAudit(
		[
			"id": .shown(as: "id", .text),
			"name": .shown(as: "name", .text),
			"sex": .shown(as: "sex", .text),
			"icuFtp": .resolved(as: "ftp", precedence: 1),
			"icuLthr": .resolved(as: ProfileField.lthr.rawValue, precedence: 1),
			"icuMaxHr": .resolved(as: ProfileField.maxHeartRate.rawValue, precedence: 1),
			"icuRestingHr": .resolved(as: ProfileField.restingHeartRate.rawValue, precedence: 1),
			"icuWeight": .resolved(as: ProfileField.weight.rawValue, precedence: 0),
			"weight": .resolved(as: ProfileField.weight.rawValue, precedence: 1),
			"icuDateOfBirth": .leftOut(
				"the coach is shown the age and the date stays on the phone"),
		], phoneOnly: ["ageYears", "ftpUsable", "ftpNotice", "units"])

	static let settingsProjection = NpmProjectionAudit([
		"types": .shown(as: "sports", .list(renaming: [:])),
		"ftp": .resolved(as: "ftp", precedence: 0),
		"lthr": .resolved(as: ProfileField.lthr.rawValue, precedence: 0),
		"maxHr": .resolved(as: ProfileField.maxHeartRate.rawValue, precedence: 0),
		"restingHr": .resolved(as: ProfileField.restingHeartRate.rawValue, precedence: 0),
		"weight": .resolved(as: ProfileField.weight.rawValue, precedence: 2),
		"indoorFtp": .measured(ProfileField.indoorFTP),
		"wPrime": .measured(ProfileField.wPrime),
		"pMax": .measured(ProfileField.maxPower),
		"sweetSpotMin": .measured(ProfileField.sweetSpotMin),
		"sweetSpotMax": .measured(ProfileField.sweetSpotMax),
		"powerZones": .shown(as: "powerZones", .ladderBounds),
		"powerZoneNames": .shown(as: "powerZones", .ladderNames),
		"hrZones": .shown(as: "heartRateZones", .ladderBounds),
		"hrZoneNames": .shown(as: "heartRateZones", .ladderNames),
		"thresholdPace": .leftOut("the phone coaches cycling only"),
		"paceUnits": .leftOut("the phone coaches cycling only"),
	])

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
