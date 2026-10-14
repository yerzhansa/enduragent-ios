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
	func commandChecksEveryTableItIsGivenAgainstTheUnitsThatTableDeclares() throws {
		let result = try Scratch(files: [
			"coverage/milestone-3.json": #"{"units": {"1.1": 2}, "criteria": []}"#,
			"coverage/milestone-4.json": #"{"units": {"4.1": 1}, "criteria": []}"#,
		]).runCommand(tables: ["coverage/milestone-3.json", "coverage/milestone-4.json"])
		#expect(result.status == 1)
		#expect(
			result.errors == [
				"coverage/milestone-3.json: 1.1.1 [missing-criterion] unit 1.1",
				"coverage/milestone-3.json: 1.1.2 [missing-criterion] unit 1.1",
				"coverage/milestone-4.json: 4.1.1 [missing-criterion] unit 4.1",
			])
		#expect(
			result.output == [
				"check-coverage: coverage/milestone-3.json: 0 criteria; 2 problems.",
				"check-coverage: coverage/milestone-4.json: 0 criteria; 1 problems.",
			])
	}

	@Test(
		.timeLimit(.minutes(1)),
		arguments: [
			nil, #"{"criteria": ["#, #"{"criteria": []}"#, #"{"units": {}, "criteria": []}"#,
			#"{"units": {"1.1": 0}, "criteria": []}"#, #"{"units": {"1.1": 1.5}, "criteria": []}"#,
			#"{"units": {"1.1": "2"}, "criteria": []}"#,
		])
	func tableThatCannotBeReadStopsTheCommandWithItsOwnStatus(_ table: String?) throws {
		let result = try Scratch(files: table.map { ["coverage/milestone-3.json": $0] } ?? [:])
			.runCommand(tables: ["coverage/milestone-3.json"])
		#expect(result.status == 2)
		#expect(result.output.isEmpty)
		#expect(result.errors.count == 1)
		#expect(
			result.errors.first?.hasPrefix(
				"check-coverage: coverage/milestone-3.json could not be read")
				== true)
	}

	@Test(.timeLimit(.minutes(1)))
	func commandWithoutATableShowsItsUsage() throws {
		let result = try Scratch(files: [:]).runCommand(tables: [])
		#expect(result.status == 2)
		#expect(result.errors == ["Usage: check-coverage [--root repository] table..."])
	}
}

struct CoverageCase: Sendable, CustomTestStringConvertible {
	static let packageTests = "Tests/ReadTests.swift"
	static let proofs = "UITests/ShortcutProofs.swift"
	static let outside = "../Outside/ReadTests.swift"
	static let page = "features/chat.md"
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

			@Test(.timeLimit(.minutes(1)), arguments: [(1, (2, 3))])
			@MainActor
			func pairIsRead(_ pair: (Int, (Int, Int))) {}

			private func range(of text: String) -> Range<Int> { 0..<1 }
		}
		""",
		proofs: """
		final class ShortcutProof: XCTestCase {
			func testPick() {
				XCTAssertTrue(launch().buttons["{"].exists)
			}

			private func launch() -> XCUIApplication { XCUIApplication() }
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
			name: "listed test file that declares the function is outside the repository",
			rows: replacing(0, with: row("1.1.1", function("rangeIsRefused", in: outside))),
			files: sources.merging([outside: sources[packageTests, default: ""]]) { $1 },
			problems: ["1.1.1 [missing-test-file] \(outside)"]),
		CoverageCase(
			name: "listed test function was renamed",
			rows: replacing(0, with: row("1.1.1", function("rangeIsRefuse"))),
			problems: ["1.1.1 [missing-test-function] \(packageTests) rangeIsRefuse"]),
		CoverageCase(
			name: "listed test function takes arguments under further attributes",
			rows: replacing(0, with: row("1.1.1", function("pairIsRead")))),
		CoverageCase(
			name: "listed test function is a helper of the test file",
			rows: replacing(0, with: row("1.1.1", function("range"))),
			problems: ["1.1.1 [missing-test-function] \(packageTests) range"]),
		CoverageCase(
			name: "listed proof method is a helper of the proof class",
			rows: replacing(1, with: row("1.1.2", proof("ShortcutProof", "launch"))),
			problems: ["1.1.2 [missing-proof-method] \(proofs) ShortcutProof.launch"]),
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
			name: "a part checked by hand is named beside the tests with its page",
			rows: replacing(0, with: row("1.1.1", listed, handCheck("The trait.", in: page))),
			files: sources.merging([page: "Check the trait with VoiceOver."]) { $1 }),
		CoverageCase(
			name: "hand check names no part",
			rows: replacing(0, with: row("1.1.1", listed, handCheck("", in: page))),
			files: sources.merging([page: "Check the trait with VoiceOver."]) { $1 },
			problems: ["1.1.1 [empty-hand-check]"]),
		CoverageCase(
			name: "hand check names no page",
			rows: replacing(0, with: row("1.1.1", listed, handCheck("The trait.", in: ""))),
			problems: ["1.1.1 [empty-hand-check]"]),
		CoverageCase(
			name: "hand check names a page that does not exist",
			rows: replacing(0, with: row("1.1.1", listed, handCheck("The trait.", in: page))),
			problems: ["1.1.1 [missing-hand-check-file] \(page)"]),
		CoverageCase(
			name: "hand check alone is neither a test nor a mark",
			rows: replacing(
				2,
				with: #"{"id": "1.2.1", "statement": "S.", \#(handCheck("The trait.", in: page))}"#),
			files: sources.merging([page: "Check the trait with VoiceOver."]) { $1 },
			problems: ["1.2.1 [no-proof]"]),
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

	static func handCheck(_ part: String, in file: String) -> String {
		#""checkedByHand": {"part": "\#(part)", "described": "\#(file)"}"#
	}

	static func row(_ identifier: String, _ test: String, _ members: String...) -> String {
		(["{\"id\": \"\(identifier)\"", #""statement": "S.""#, #""tests": [\#(test)]"#] + members)
			.joined(separator: ", ") + "}"
	}

	static func replacing(_ index: Int, with row: String) -> [String] {
		var rows = complete
		rows[index] = row
		return rows
	}

	func check() throws -> (problems: [String], rows: Int) {
		let path = "coverage/sample.json"
		let table = #"""
			{"units": {"1.1": 2, "1.2": 1}, "criteria": [\#(rows.joined(separator: ","))]}
			"""#
		return try Scratch(files: files.merging([path: table]) { $1 }).inRoot { root in
			let lines = Lines()
			let problems = Problems { lines.lines.append($0) }
			let count = try CoverageChecker(root: root, table: path, problems: problems).run()
			return (lines.lines, count)
		}
	}
}

struct Scratch {
	let files: [String: String]

	func inRoot<Result>(_ body: (String) throws -> Result) throws -> Result {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ios-coverage-check-\(UUID().uuidString)", isDirectory: true)
		let root = folder.appendingPathComponent("Repository", isDirectory: true)
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
		try FileManager.default.removeItem(at: folder)
		return try outcome.get()
	}

	func runCommand(tables: [String]) throws -> (status: Int32, output: [String], errors: [String])
	{
		try inRoot { root in
			let output = Lines()
			let errors = Lines()
			let status = try CheckCoverage.run(
				arguments: ["--root", root] + tables, directory: root,
				output: { output.lines.append($0) }, errors: { errors.lines.append($0) })
			return (status, output.lines, errors.lines)
		}
	}
}

private final class Lines {
	var lines: [String] = []
}
