import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

struct CloseoutWriterTests {
	static let tableEnd = "\t]\n}\n"
	static let decisionRow =
		#"{"id": "D04", "group": "decision", "status": "met", "evidence": [{"record": "ADR-0085"}], "differences": [], "waitsOn": []},"#

	@Test(.timeLimit(.minutes(1)))
	func aTableWithNoSectionGainsItAfterOpenAndKeepsEveryOtherByte() throws {
		let written = try CloseoutFixture().written()
		#expect(written.original.hasSuffix(Self.tableEnd))
		let kept = String(written.original.dropLast(Self.tableEnd.count))
		#expect(written.first.hasPrefix(kept + "\t],\n"))
		let section = written.first.dropFirst(kept.count)
			.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		#expect(
			Array(section.prefix(4)) == [
				"\t],", "\t\"closeout\": {", "\t\t\"stage\": \"building\",", "\t\t\"rows\": [",
			])
		let rows = Array(section.dropFirst(4).prefix { $0.hasPrefix("\t\t\t") })
		#expect(
			rows.map { $0.components(separatedBy: ", ").first ?? "" }
				== CloseoutFixture.checkerRetained.map { "\t\t\t{\"id\": \($0.id.quotedAsJSON)" })
		#expect(rows.dropLast().allSatisfy { $0.hasSuffix("},") })
		#expect(rows.last?.hasSuffix("]}") == true)
		#expect(rows.contains("\t\t\t" + Self.decisionRow))
		#expect(Array(section.dropFirst(4 + rows.count)) == ["\t\t]", "\t}", "}", ""])
	}

	@Test(.timeLimit(.minutes(1)))
	func aTableWithASectionHasOnlyThoseLinesReplaced() throws {
		var later = CloseoutFixture()
		later.handEvidence.append(("D04", #"{"record": "ADR-0080"}"#))
		later.stage = "final"
		let written = try CloseoutFixture().written(rewritingWith: later)
		let opening = try #require(written.first.range(of: CloseoutLayout.opening))
		let kept = String(written.first[..<opening.lowerBound])
		#expect(kept.hasSuffix("\t],\n"))
		#expect(written.second.hasPrefix(kept + CloseoutLayout.opening + "\n"))
		#expect(written.second.hasSuffix("\t\t]\n\t}\n}\n"))
		let changed = Set(written.second.components(separatedBy: "\n"))
			.subtracting(written.first.components(separatedBy: "\n"))
		#expect(
			changed == [
				"\t\t\"stage\": \"final\",",
				"\t\t\t"
					+ Self.decisionRow.replacingOccurrences(
						of: #"[{"record": "ADR-0085"}]"#,
						with: #"[{"record": "ADR-0085"}, {"record": "ADR-0080"}]"#),
			])
		#expect(
			written.second.components(separatedBy: "\n").count
				== written.first.components(separatedBy: "\n").count)
	}

	@Test(.timeLimit(.minutes(1)))
	func aSecondRunChangesNothing() throws {
		let written = try CloseoutFixture().written()
		#expect(written.second == written.first)
	}

	@Test(.timeLimit(.minutes(1)))
	func aHandEditedRowIsWrittenBackAsDerived() throws {
		let written = try CloseoutFixture().written(editing: {
			$0.replacingOccurrences(
				of: Self.decisionRow, with: #"{"id": "D04", "status": "open"},"#)
		})
		#expect(written.first.contains(Self.decisionRow))
		#expect(written.second == written.first)
	}
}
