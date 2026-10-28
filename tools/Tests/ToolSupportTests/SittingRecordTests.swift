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
}
