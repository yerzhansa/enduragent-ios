import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

struct CoverageCheckerTests {
	@Test(.timeLimit(.minutes(1)), arguments: CoverageCase.all)
	func reportsExactlyTheProblemsOfATable(_ coverageCase: CoverageCase) throws {
		let result = try coverageCase.check()
		#expect(result.problems == coverageCase.problems)
		#expect(result.rows == coverageCase.rows.count)
	}

	@Test(.timeLimit(.minutes(1)))
	func emptyTableFailsTheCommandAndNamesEveryCriterionOfTheMilestone() throws {
		let result = try Scratch(files: ["coverage/milestone-3.json": #"{"criteria": []}"#])
			.runCommand()
		#expect(result.status == 1)
		#expect(result.errors.count == 134)
		#expect(result.errors.first == "1.1.1 [missing-criterion] unit 1.1")
		#expect(result.errors.last == "8.4.6 [missing-criterion] unit 8.4")
		#expect(result.output == ["check-coverage: 0 criteria; 134 problems."])
	}

	@Test(.timeLimit(.minutes(1)))
	func tableThatCannotBeReadStopsTheCommandWithItsOwnStatus() throws {
		let missing = try Scratch(files: [:]).runCommand()
		#expect(missing.status == 2)
		#expect(missing.output.isEmpty)
		let broken = try Scratch(files: ["coverage/milestone-3.json": #"{"criteria": ["#])
			.runCommand()
		#expect(broken.status == 2)
		#expect(broken.errors.count == 1)
	}
}

struct CoverageCase: Sendable, CustomTestStringConvertible {
	static let packageTests = "Tests/ReadTests.swift"
	static let proofs = "UITests/ShortcutProofs.swift"
	static let listed = function("rangeIsRefused")
	static let picked = proof("ShortcutProof", "testPick")
	static let complete = [
		#"{"id": "1.1.1", "statement": "A reversed range is refused.", "tests": [\#(listed)]}"#,
		#"{"id": "1.1.2", "statement": "A picked shortcut fills.", "tests": [\#(picked)]}"#,
		#"{"id": "1.2.1", "statement": "The coach answers.", "phoneSession": "Needs a model."}"#,
	]
	static let sources = [
		packageTests: """
		struct ReadTests {
			@Test func rangeIsRefused() throws {
				let text = "func onlyInText() { \\(run { "}" }) }"
				#expect(text.isEmpty)
			}
		}
		""",
		proofs: """
		final class ShortcutProof: XCTestCase {
			func testPick() {
				XCTAssertTrue(app.buttons["{"].exists)
			}
		}

		final class LanguageProof: XCTestCase {
			func testShortcuts() {}
		}
		""",
	]

	let name: String
	var rows = CoverageCase.complete
	var files = CoverageCase.sources
	var problems: [String] = []

	var testDescription: String { name }

	static let all = [
		CoverageCase(name: "every criterion has a declared test or a mark"),
		CoverageCase(
			name: "a mark that no test can show the criterion stands in for a test",
			rows: replacing(
				2, with: #"{"id": "1.2.1", "statement": "S.", "noAutomatedProof": "Types."}"#)),
		CoverageCase(
			name: "listed test file does not exist",
			files: sources.filter { $0.key != packageTests },
			problems: ["1.1.1 [missing-test-file] \(packageTests)"]),
		CoverageCase(
			name: "listed test file is outside the repository",
			rows: replacing(0, with: row("1.1.1", function("a", in: "../\(packageTests)"))),
			problems: ["1.1.1 [missing-test-file] ../\(packageTests)"]),
		CoverageCase(
			name: "listed test function was renamed",
			rows: replacing(0, with: row("1.1.1", function("rangeIsRefuse"))),
			problems: ["1.1.1 [missing-test-function] \(packageTests) rangeIsRefuse"]),
		CoverageCase(
			name: "listed test function is only named inside a string",
			rows: replacing(0, with: row("1.1.1", function("onlyInText"))),
			problems: ["1.1.1 [missing-test-function] \(packageTests) onlyInText"]),
		CoverageCase(
			name: "listed proof method belongs to another class of the file",
			rows: replacing(1, with: row("1.1.2", proof("ShortcutProof", "testShortcuts"))),
			problems: ["1.1.2 [missing-proof-method] \(proofs) ShortcutProof.testShortcuts"]),
		CoverageCase(
			name: "listed proof class is not declared in the file",
			rows: replacing(1, with: row("1.1.2", proof("ShortcutProofs", "testPick"))),
			problems: ["1.1.2 [missing-proof-method] \(proofs) ShortcutProofs.testPick"]),
		CoverageCase(
			name: "listed test names neither a function nor a proof method",
			rows: replacing(0, with: row("1.1.1", #"{"file": "\#(packageTests)"}"#)),
			problems: ["1.1.1 [test-without-name] \(packageTests)"]),
		CoverageCase(
			name: "criterion has neither a test nor a mark",
			rows: replacing(2, with: #"{"id": "1.2.1", "statement": "The coach answers."}"#),
			problems: ["1.2.1 [no-proof]"]),
		CoverageCase(
			name: "criterion has an empty test list and an empty mark",
			rows: replacing(
				2, with: #"{"id": "1.2.1", "statement": "S.", "tests": [], "phoneSession": ""}"#),
			problems: ["1.2.1 [no-proof]"]),
		CoverageCase(
			name: "criterion has a test and a mark",
			rows: replacing(
				0,
				with:
					#"{"id": "1.1.1", "statement": "S.", "tests": [\#(listed)], "phoneSession": "P"}"#
			),
			problems: ["1.1.1 [more-than-one-proof]"]),
		CoverageCase(
			name: "criterion has no statement",
			rows: replacing(0, with: #"{"id": "1.1.1", "tests": [\#(listed)]}"#),
			problems: ["1.1.1 [no-statement]"]),
		CoverageCase(
			name: "criterion identifier appears twice",
			rows: complete + [complete[1]],
			problems: ["1.1.2 [duplicate-criterion]"]),
		CoverageCase(
			name: "unit has fewer criteria than its count",
			rows: [complete[0], complete[2]],
			problems: ["1.1.2 [missing-criterion] unit 1.1"]),
		CoverageCase(
			name: "unit has no criterion at all",
			rows: Array(complete.prefix(2)),
			problems: ["1.2.1 [missing-criterion] unit 1.2"]),
		CoverageCase(
			name: "criterion is not one of the milestone",
			rows: complete + [row("1.2.2", listed)],
			problems: ["1.2.2 [unknown-criterion]"]),
		CoverageCase(
			name: "row has no identifier",
			rows: complete + [#"{"statement": "S.", "tests": [\#(listed)]}"#],
			problems: ["row 4 [no-identifier]"]),
	]

	static func function(_ name: String, in file: String = packageTests) -> String {
		#"{"file": "\#(file)", "function": "\#(name)"}"#
	}

	static func proof(_ type: String, _ method: String) -> String {
		#"{"file": "\#(proofs)", "class": "\#(type)", "method": "\#(method)"}"#
	}

	static func row(_ identifier: String, _ test: String) -> String {
		#"{"id": "\#(identifier)", "statement": "S.", "tests": [\#(test)]}"#
	}

	static func replacing(_ index: Int, with row: String) -> [String] {
		var rows = complete
		rows[index] = row
		return rows
	}

	func check() throws -> (problems: [String], rows: Int) {
		let milestone = Milestone(
			table: "coverage/sample.json",
			units: [.init(name: "1.1", criteria: 2), .init(name: "1.2", criteria: 1)])
		let table = #"{"criteria": [\#(rows.joined(separator: ","))]}"#
		return try Scratch(files: files.merging([milestone.table: table]) { $1 }).inRoot { root in
			let lines = Lines()
			let problems = Problems { lines.lines.append($0) }
			let count = try CoverageChecker(root: root, milestone: milestone, problems: problems)
				.run()
			return (lines.lines, count)
		}
	}
}

struct Scratch {
	let files: [String: String]

	func inRoot<Result>(_ body: (String) throws -> Result) throws -> Result {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ios-coverage-check-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let outcome = Swift.Result {
			for (file, content) in files {
				let url = root.appendingPathComponent(file)
				try FileManager.default.createDirectory(
					at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				try Data(content.utf8).write(to: url)
			}
			return try body(try FileSystem.realPath(root.path))
		}
		try FileManager.default.removeItem(at: root)
		return try outcome.get()
	}

	func runCommand() throws -> (status: Int32, output: [String], errors: [String]) {
		try inRoot { root in
			let output = Lines()
			let errors = Lines()
			let status = try CheckCoverage.run(
				arguments: ["--root", root], directory: root,
				output: { output.lines.append($0) }, errors: { errors.lines.append($0) })
			return (status, output.lines, errors.lines)
		}
	}
}

private final class Lines {
	var lines: [String] = []
}
