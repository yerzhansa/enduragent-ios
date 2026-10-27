import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct JournalLineTests {
	static let at = Date(timeIntervalSince1970: 1_793_092_443.120_7)

	static func lines() throws -> [JournalLine] {
		let model = try #require(ModelRef(ModelID(rawValue: "anthropic/claude-sonnet-4.5:beta")))
		let chat = try #require(ChatRef(ChatID.main))
		return [
			.problem(
				ProblemLine(
					.providerFailure, subject: .attempt(fixedUlid(1)),
					cause: ProblemCode("provider").then(ProblemCode("serverError", 502)),
					detail: ProblemCode("http", 502).then(ProblemCode("openRouter", 502)))),
			.problem(ProblemLine(.settlementUnsaved, subject: .turn(fixedUlid(2)))),
			.problem(ProblemLine(.compactionFailed, subject: .chat(chat))),
			.problem(
				ProblemLine(
					.secureStorageFailed, subject: .slot(CredentialSlotCode(.intervalsConnection)))),
			.problem(ProblemLine(.planSaveStalled, subject: .confirmation(fixedUlid(3)))),
			.problem(
				ProblemLine(
					.skippedRecord, cause: ProblemCode("newerVersion", 3),
					row: SkippedRowText(
						kind: ScrubbedText(scrubbing: "user\nMessage"),
						ulid: ScrubbedText(scrubbing: "row-7")))),
			.usage(
				UsageLine(
					origin: .turn(turn: fixedUlid(4), attempt: fixedUlid(5), ending: .replied),
					model: model, calls: 2, failedCalls: 1, inputTokens: 1_200, outputTokens: 340,
					cost: .reported(0.004_25), durationMilliseconds: 8_150)),
			.usage(
				UsageLine(
					origin: .memorySave(attempt: fixedUlid(6), ending: .partial), model: model,
					calls: 1, failedCalls: 0, inputTokens: 900, outputTokens: 0, cost: .unreported,
					durationMilliseconds: 2_010)),
		]
	}

	@Test func everyJournalLineCaseEncodesToOneObjectAndDecodesBackEqual() throws {
		for line in try Self.lines() {
			let stamped = StampedLine(at: Self.at, line: line)
			let encoded = try stamped.encoded()
			#expect(!encoded.contains(UInt8(ascii: "\n")))
			#expect(try JSONSerialization.jsonObject(with: encoded) is [String: Any])
			#expect(try StampedLine(decoding: encoded) == stamped)
		}
	}

	@Test func decodingRefusesAProblemLineWithAnUnknownKind() {
		let line = #"{"at":"2026-10-27T09:14:03.120Z","problem":{"kind":"diskOnFire"}}"#
		#expect(throws: DecodingError.self) { try StampedLine(decoding: Data(line.utf8)) }
	}

	@Test(arguments: [
		"ledger unavailable", "ledger.unavailable\n", "tool_failed", "url(-1009)\"",
		"ledger.ünavailable", "9lives", "",
	])
	func decodingRefusesACodeWithACharacterOutsideItsSet(_ code: String) throws {
		let object: [String: Any] = [
			"at": "2026-10-27T09:14:03.120Z",
			"problem": ["kind": "recoveryUnavailable", "cause": code],
		]
		let line = try JSONSerialization.data(withJSONObject: object)
		#expect(throws: DecodingError.self) { try StampedLine(decoding: line) }
	}

	@Test func decodingAStoredSkippedRowScrubsItAgain() throws {
		let stored =
			#"{"at":"2026-10-27T09:14:03.120Z","problem":{"kind":"skippedRecord","row":{"kind":"sk-or-v1-abc","ulid":"Bearer xyz"}}}"#
		let decoded = try StampedLine(decoding: Data(stored.utf8))
		guard case .problem(let problem) = decoded.line else {
			Issue.record("A stored problem decoded as \(decoded.line)")
			return
		}
		let row = try #require(problem.row)
		#expect(row.kind.text == "[redacted]")
		#expect(row.ulid.text == "[redacted]")
		let encoded = try #require(String(data: try decoded.encoded(), encoding: .utf8))
		#expect(!encoded.contains("sk-or-v1-abc"))
		#expect(!encoded.contains("Bearer xyz"))
	}

	static let projectedCodes: [(FailureCode, String)] = [
		(.ledger(.unavailable), "ledger.unavailable"),
		(.url(-1009), "url(-1009)"),
		(.type(.signInFailure), "type.signInFailure"),
		(
			.unclassified(ErrorTypeName("EnduragentCoachTests.SecretBearingError")),
			"unclassified.EnduragentCoachTests.SecretBearingError"
		),
	]

	@Test(arguments: projectedCodes)
	func aFailureCodeProjectsToItsProblemCode(_ failure: FailureCode, _ expected: String) throws {
		#expect(failure.code.rawValue == expected)
		let line = StampedLine(
			at: Self.at, line: .problem(ProblemLine(.recoveryUnavailable, cause: failure.code)))
		#expect(try StampedLine(decoding: line.encoded()) == line)
	}

	@Test(arguments: PackageErrorType.allCases)
	func everyPackageErrorTypeCodeIsWritable(_ type: PackageErrorType) throws {
		let line = StampedLine(
			at: Self.at,
			line: .problem(ProblemLine(.recoveryUnavailable, cause: FailureCode.type(type).code)))
		#expect(try StampedLine(decoding: line.encoded()) == line)
	}
}
