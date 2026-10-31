import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct DisplayZonesTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func ftpOutsideRangeThrows() {
		#expect(throws: ToolInputError.self) {
			_ = try DisplayZones.table(ftpWatts: 49)
		}
		#expect(throws: ToolInputError.self) {
			_ = try DisplayZones.table(ftpWatts: 601)
		}
	}

	@Test func rowsEqualNpmAtEveryBoundaryFtp() async throws {
		let accepted = try npmCases().filter { $0.rows != nil }
		#expect(accepted.count >= 6)
		#expect(accepted.first?.arguments == #"{"ftpWatts":50}"#)
		#expect(accepted.last?.arguments == #"{"ftpWatts":600}"#)

		let answers = try await coachAnswers(to: accepted.map(\.arguments))

		for (answer, npm) in zip(answers, accepted) {
			let rows = try #require(npm.rows)
			#expect(
				Array(answer.canonicalDigestInput().utf8)
					== Array(rows.canonicalDigestInput().utf8),
				"\(npm.arguments)")
		}
	}

	@Test func sixRowsInOrderAndOnlySweetSpotOverlaps() async throws {
		let rows = try #require(
			try await coachAnswers(to: [#"{"ftpWatts":250}"#]).first?.arrayValue)

		#expect(
			rows.map { $0.objectFields["label"]?.stringValue } == [
				"Z1 Active Recovery", "Z2 Endurance", "Z3 Tempo", "Sweet Spot (88-94%)",
				"Z4 Threshold", "Z5 VO2max",
			])
		#expect(
			rows.map { $0.objectFields["overlaps"] } == [nil, nil, nil, .bool(true), nil, nil])
	}

	@Test func unusableFtpReturnsAnErrorAndTextFtpReturnsTheRows() async throws {
		let cases = try npmCases()
		let text = #"{"ftpWatts":"250"}"#
		let refusedByBoth = cases.filter { $0.rows == nil && $0.arguments != text }
		#expect(
			refusedByBoth.map(\.arguments) == [
				"{}", #"{"ftpWatts":250.5}"#, #"{"ftpWatts":49}"#, #"{"ftpWatts":601}"#,
			])
		#expect(cases.contains { $0.rows == nil && $0.arguments == text })
		let wholeNumber = try #require(
			cases.first { $0.arguments == #"{"ftpWatts":250}"# }?.rows)

		let answers = try await coachAnswers(to: refusedByBoth.map(\.arguments) + [text])

		for (answer, refused) in zip(answers, refusedByBoth) {
			#expect(answer.objectFields["error"] == .string("invalid_ftp"), "\(refused.arguments)")
			#expect(answer.arrayValue == nil, "\(refused.arguments)")
			#expect(
				!answer.canonicalDigestInput().contains("Z1 Active Recovery"),
				"\(refused.arguments)")
		}
		#expect(answers.last == wholeNumber)
	}

	@Test func offeredDescriptionAndSchemaEqualNpm() async throws {
		let fixture = try boundaries()
		let npm = try #require(fixture["parameters"]?.objectFields)

		_ = try await coachAnswers(to: [#"{"ftpWatts":250}"#])

		let offered = try #require(
			transport.requests.first?.tools.first { $0.name == .calculateZones })
		#expect(.string(offered.description) == fixture["description"])
		#expect(
			offered.description
				== "Calculate power-zone watt ranges from FTP watts (7-zone numbering)")
		let phone = offered.parameters.objectFields
		#expect(phone == npm.filter { phone.keys.contains($0.key) })
		#expect(
			Set(npm.keys).subtracting(phone.keys) == ["$schema", "additionalProperties"])
	}

	@Test func zoneReferenceTopicStillHasSevenZonesAndTheSweetSpotOverlap() async throws {
		let npm = try #require(try boundaries()["zoneReference"]?.stringValue)

		_ = try await coachAnswers(to: [#"{"ftpWatts":250}"#])

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(system.contains("## Skill: cycling-zone-reference\n\n" + npm))
		for zone in [
			"| Z1 | Active Recovery | < 55% |", "| Z2 | Endurance | 56-75% |",
			"| Z3 | Tempo | 76-90% |", "| Z4 | Threshold | 91-105% |",
			"| Z5 | VO2max | 106-120% |", "| Z6 | Anaerobic | 121-150% |",
			"| Z7 | Neuromuscular | > 150% |",
		] {
			#expect(system.contains(zone))
		}
		#expect(
			system.contains(
				"""
				Sweet Spot = 88-94% FTP — a named sub-range spanning the top of Z3 Tempo into
				the bottom of Z4 Threshold, not a numbered zone
				"""))
	}

	private func coachAnswers(to arguments: [String]) async throws -> [JSONValue] {
		transport.respond = ScriptedReply.sequence(
			arguments.map { .toolCall(name: "calculate_zones", arguments: $0) } + [
				.finish(reason: .toolCalls), .text("Done."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store)

		_ = try await coach.sendAndSettle("What are my zones?")

		let results = try #require(transport.requests.last).messages.filter { $0.role == .tool }
		try #require(results.count == arguments.count)
		return try results.map {
			try #require(try JSONValue.parse($0.content).objectFields["data"])
		}
	}

	private func boundaries() throws -> [String: JSONValue] {
		try JSONValue.parse(
			try #require(String(data: try fixtureData("zones-ts-boundaries"), encoding: .utf8))
		).objectFields
	}

	private func npmCases() throws -> [(arguments: String, rows: JSONValue?)] {
		try #require(try boundaries()["cases"]?.arrayValue).map {
			let npm = try #require($0.objectFields["npm"])
			return (
				arguments: try #require($0.objectFields["arguments"]?.stringValue),
				rows: npm == .null ? nil : npm
			)
		}
	}
}
