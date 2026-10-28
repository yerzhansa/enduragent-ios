import Foundation
import Testing
import ToolSupport

struct SittingRecordTests {
	static func record(_ verdict: String, date: String = "2026-11-02") throws -> SittingRecord {
		let text =
			#"{"steps": {"closeout/lifecycle": {"verdict": \#(verdict.quotedAsJSON), "date": \#(date.quotedAsJSON)}}}"#
		return try JSONDecoder().decode(SittingRecord.self, from: Data(text.utf8))
	}

	@Test func eachVerdictDecodesWithItsDate() throws {
		let decoded = try ["pass", "fail the reply named no date", "blocked no second phone"].map {
			try Self.record($0).steps["closeout/lifecycle"]
		}
		#expect(
			decoded.map { $0?.verdict } == [
				.pass, .fail(check: "the reply named no date"), .blocked(reason: "no second phone"),
			])
		#expect(decoded.map { $0?.date } == ["2026-11-02", "2026-11-02", "2026-11-02"])
	}

	@Test(arguments: [
		"", "passed", "Pass", "pass ", "fail", "fail ", "blocked", "blocked  ", "skip x",
	])
	func anyOtherVerdictIsRefused(_ verdict: String) {
		#expect(throws: DecodingError.self) { try Self.record(verdict) }
	}

	@Test(arguments: ["", "2026-11-2", "02-11-2026", "yesterday"])
	func aVerdictWithoutADayIsRefused(_ date: String) {
		#expect(throws: DecodingError.self) { try Self.record("pass", date: date) }
	}

	@Test func aVerdictTypedAtThePromptReplacesTheStepsEarlierOne() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("sitting-\(UUID().uuidString)").path
		try FileManager.default.createDirectory(
			atPath: NodePath.join(root, "coverage/closeout"), withIntermediateDirectories: true)
		let outcome = Result { try Self.recordAtThePrompt(root: root) }
		try FileManager.default.removeItem(atPath: root)
		try outcome.get()
	}

	static func recordAtThePrompt(root: String) throws {
		try Data("{\"steps\": {}}\n".utf8).write(
			to: URL(fileURLWithPath: NodePath.join(root, SittingRecord.path)))
		#expect(throws: PhoneRefusal.self) {
			try SittingRecord.record("passed", for: "m4/list", on: "2026-11-02", root: root)
		}
		#expect(
			try SittingRecord.record(
				"blocked no signal", for: "m4/list", on: "2026-11-02", root: root)
				== .blocked(reason: "no signal"))
		_ = try SittingRecord.record(
			"fail the lap table", for: "closeout/about", on: "2026-11-02", root: root)
		_ = try SittingRecord.record("pass", for: "m4/list", on: "2026-11-03", root: root)
		let steps = try SittingRecord.load(root: root).steps
		#expect(steps.count == 2)
		#expect(steps["m4/list"]?.verdict == .pass)
		#expect(steps["m4/list"]?.date == "2026-11-03")
		#expect(steps["closeout/about"]?.verdict == .fail(check: "the lap table"))
	}
}
