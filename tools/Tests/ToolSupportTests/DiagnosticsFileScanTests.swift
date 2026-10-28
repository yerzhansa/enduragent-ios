import Foundation
import Testing
import ToolSupport

struct DiagnosticsFileScanTests {
	static let athlete = "i" + String(12_345_678)
	static let key = "key-" + String(repeating: "7", count: 12)
	static let fixed = "Add an easy 45-minute ride tomorrow"
	static let usage =
		#"{"at": "2026-10-28T08:00:00Z", "usage": {"origin": "chat", "turn": "t1", "attempt": 1, "ending": "finished", "model": "provider/model", "calls": 1, "failedCalls": 0, "inputTokens": 120, "outputTokens": 40, "cost": 0.01, "durationMilliseconds": 900}}"#

	static func file(lines: [String] = [usage], note: String = "ready") -> Data {
		Data(
			"""
			{"format": 1, "made": "2026-10-28T08:00:00Z", "app": {"version": "0.1.0", "note": \(note.quotedAsJSON)}, "device": {}, "access": {}, "training": {}, "language": "en", "records": [], "journal": [], "lines": [\(lines.joined(separator: ", "))]}
			""".utf8)
	}

	static func problems(_ file: Data) throws -> [String] {
		try DiagnosticsFileScan.problems(
			in: file,
			inputs: DiagnosticsScanInputs(
				athleteID: athlete, intervalsKey: key, fixedMessages: [fixed]))
	}

	@Test func aCleanFileWithAUsageLinePasses() throws {
		#expect(try Self.problems(Self.file()) == [])
	}

	@Test func anAthleteIdShapeFails() throws {
		#expect(
			try Self.problems(Self.file(note: "i1234567")) == [
				"The file holds an athlete id shape."
			])
	}

	@Test func theTestAccountsAthleteIdFails() throws {
		#expect(
			try Self.problems(Self.file(note: Self.athlete)) == [
				"The file holds the test account's athlete id.",
				"The file holds an athlete id shape.",
			])
	}

	@Test func anOpenRouterKeyShapeFails() throws {
		let secret = "sk-or-v1-" + String(repeating: "ab12", count: 16)
		#expect(
			try Self.problems(Self.file(note: secret)) == [
				"The file holds the secret shape sk-or-v1-.",
				"The file holds the secret shape sk-.",
			])
	}

	@Test func theIntervalsKeyFails() throws {
		#expect(
			try Self.problems(Self.file(note: Self.key)) == ["The file holds the intervals key."])
	}

	@Test func aFixedCloseoutMessageFails() throws {
		#expect(
			try Self.problems(Self.file(note: Self.fixed)) == [
				"The file holds the message \(Self.fixed.quotedAsJSON)."
			])
	}

	@Test func aFileWithoutAUsageLineFails() throws {
		#expect(
			try Self.problems(
				Self.file(lines: [#"{"at": "2026-10-28T08:00:00Z", "problem": "offline"}"#]))
				== ["The file has no usage line with a model and tokens."])
	}

	@Test func theCommittedCloseoutPlanFixesTheFillAndUpdateMessages() throws {
		let messages = try PhoneSessionTests.committed("closeout").quotedMessages(
			of: ["closeout/fill", "closeout/update"])
		#expect(messages.contains(Self.fixed))
		#expect(messages.contains("When is my gran fondo?"))
	}
}
