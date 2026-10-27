import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

extension CoverageCheckerTests {
	@Test(.timeLimit(.minutes(1)), arguments: CarriedCase.proofs)
	func carriedRowStatesItsBehaviorAndNamesOneReplacementOrAnADR(_ carriedCase: CarriedCase)
		throws
	{
		#expect(try carriedCase.check() == carriedCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: CarriedCase.replacements)
	func carriedReplacementIsATestThatExistsOutsideTheListedFiles(_ carriedCase: CarriedCase)
		throws
	{
		#expect(try carriedCase.check() == carriedCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: CarriedCase.mapping)
	func everyTestOfAListedFileThatExistsHasExactlyOneRow(_ carriedCase: CarriedCase) throws {
		#expect(try carriedCase.check() == carriedCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: CarriedCase.deleted)
	func aDeletedListedFileLeavesItsRowsStandingOnTheirReplacements(_ carriedCase: CarriedCase)
		throws
	{
		#expect(try carriedCase.check() == carriedCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: [#"[]"#, #""files""#])
	func carriedSectionThatIsNotAGroupStopsTheCommand(_ carried: String) throws {
		let table =
			#"{"units": {"1.1": 1}, "criteria": [\#(CarriedCase.criterion)], "carried": \#(carried)}"#
		let result = try Scratch(files: ["coverage/milestone-4.json": table])
			.runCommand(tables: ["coverage/milestone-4.json"])
		#expect(result.status == 2)
		#expect(result.output.isEmpty)
		#expect(
			result.errors
				== [
					"check-coverage: coverage/milestone-4.json could not be read: the carried section is not a group"
				])
	}
}

struct CarriedCase: Sendable, CustomTestStringConvertible {
	static let oldTests = "Tests/OldTests.swift"
	static let oldProofs = "UITests/OldProofs.swift"
	static let newTests = "Tests/NewTests.swift"
	static let newProofs = "UITests/NewProofs.swift"
	static let listed = [oldTests, oldProofs]
	static let criterion = #"{"id": "1.1.1", "statement": "S.", "noAutomatedProof": "Tables."}"#
	static let approves = test(function: "approves")
	static let cancels = test(function: "cancels")
	static let card = test(proof: "OldProof", "testCard")
	static let complete = [
		row(approves, replacements: [test(function: "deskApproves", in: newTests)]),
		row(cancels, retiredBy: "ADR-0083 lets a waiting review outlive the ten-minute timer."),
		row(card, replacements: [test(proof: "NewProof", "testDesk", in: newProofs)]),
	]
	static let sources = [
		oldTests: """
		struct OldTests {
			@Test func approves() {}

			@Test(arguments: [1])
			func cancels(_ count: Int) {}

			private func helper() {}
		}
		""",
		oldProofs: """
		final class OldProof: XCTestCase {
			func testCard() {}
			private func testHidden() {}
			func launch() -> XCUIApplication { XCUIApplication() }
		}
		""",
		newTests: """
		struct NewTests {
			@Test func deskApproves() {}
		}
		""",
		newProofs: """
		final class NewProof: XCTestCase {
			func testDesk() {}
		}
		""",
	]

	let name: String
	var files = CarriedCase.listed
	var rows = CarriedCase.complete
	var sources = CarriedCase.sources
	var problems: [String] = []

	var testDescription: String { name }

	static let proofs = [
		CarriedCase(name: "every listed test has a statement and one proof"),
		CarriedCase(
			name: "a retired row may name the ADR that ADR-0083 builds on",
			rows: replacing(1, with: row(cancels, retiredBy: "ADR-0079 names the review."))),
		CarriedCase(
			name: "row names neither a replacement nor an ADR",
			rows: replacing(1, with: row(cancels)),
			problems: ["carried cancels [no-proof]"]),
		CarriedCase(
			name: "row has an empty replacement list and an empty reason",
			rows: replacing(1, with: row(cancels, replacements: [], retiredBy: "")),
			problems: ["carried cancels [no-proof]"]),
		CarriedCase(
			name: "row names both a replacement and an ADR",
			rows: replacing(
				0,
				with: row(
					approves, replacements: [test(function: "deskApproves", in: newTests)],
					retiredBy: "ADR-0083")),
			problems: ["carried approves [more-than-one-proof]"]),
		CarriedCase(
			name: "retired row names no ADR",
			rows: replacing(1, with: row(cancels, retiredBy: "A later milestone retires it.")),
			problems: ["carried cancels [retired-without-adr]"]),
		CarriedCase(
			name: "row has no statement",
			rows: replacing(
				0,
				with: row(
					approves, statement: nil,
					replacements: [test(function: "deskApproves", in: newTests)])),
			problems: ["carried approves [no-statement]"]),
	]

	static let replacements = [
		CarriedCase(
			name: "replacement function was renamed",
			rows: replacing(
				0, with: row(approves, replacements: [test(function: "deskApprove", in: newTests)])),
			problems: ["carried approves [missing-test-function] \(newTests) deskApprove"]),
		CarriedCase(
			name: "replacement file does not exist",
			sources: sources.filter { $0.key != newTests },
			problems: ["carried approves [missing-test-file] \(newTests)"]),
		CarriedCase(
			name: "replacement proof method was renamed",
			rows: replacing(
				2,
				with: row(card, replacements: [test(proof: "NewProof", "testDesks", in: newProofs)])
			),
			problems: [
				"carried OldProof.testCard [missing-proof-method] \(newProofs) NewProof.testDesks"
			]),
		CarriedCase(
			name: "replacement lives in a listed file",
			rows: replacing(0, with: row(approves, replacements: [cancels])),
			problems: ["carried approves [replacement-in-listed-file] \(oldTests)"]),
		CarriedCase(
			name: "one of two replacements is missing",
			rows: replacing(
				0,
				with: row(
					approves,
					replacements: [
						test(function: "deskApproves", in: newTests),
						test(function: "deskCancels", in: newTests),
					])),
			problems: ["carried approves [missing-test-function] \(newTests) deskCancels"]),
	]

	static let mapping = [
		CarriedCase(
			name: "a listed test function has no row",
			rows: [complete[0], complete[2]],
			problems: ["carried [unmapped-test] \(oldTests) cancels"]),
		CarriedCase(
			name: "a listed proof method has no row",
			rows: Array(complete.prefix(2)),
			problems: ["carried [unmapped-test] \(oldProofs) OldProof.testCard"]),
		CarriedCase(
			name: "a listed test appears twice",
			rows: complete + [complete[1]],
			problems: ["carried cancels [duplicate-carried-test] \(oldTests)"]),
		CarriedCase(
			name: "a row names a test that its listed file does not declare",
			rows: replacing(
				0,
				with: row(
					test(function: "approve"),
					replacements: [test(function: "deskApproves", in: newTests)])),
			problems: [
				"carried approve [missing-carried-test] \(oldTests)",
				"carried [unmapped-test] \(oldTests) approves",
			]),
		CarriedCase(
			name: "a row names a test of a file that is not listed",
			rows: complete + [
				row(test(function: "deskApproves", in: newTests), retiredBy: "ADR-0083")
			],
			problems: ["carried deskApproves [unlisted-carried-file] \(newTests)"]),
		CarriedCase(
			name: "a row names no test",
			rows: replacing(0, with: row(#"{"file": "\#(oldTests)"}"#, retiredBy: "ADR-0083")),
			problems: [
				"carried 1 [test-without-name]",
				"carried [unmapped-test] \(oldTests) approves",
			]),
		CarriedCase(
			name: "a file is listed twice",
			files: listed + [oldTests],
			problems: ["carried file 3 [duplicate-carried-file] \(oldTests)"]),
	]

	static let deleted = [
		CarriedCase(
			name: "rows of a deleted file stand on their replacements",
			sources: sources.filter { $0.key != oldTests }),
		CarriedCase(
			name: "a deleted file's row still needs its replacement",
			rows: replacing(
				0, with: row(approves, replacements: [test(function: "deskApprove", in: newTests)])),
			sources: sources.filter { $0.key != oldTests },
			problems: ["carried approves [missing-test-function] \(newTests) deskApprove"]),
		CarriedCase(
			name: "a deleted proof file's row still needs its replacement",
			sources: sources.filter { $0.key != oldProofs && $0.key != newProofs },
			problems: ["carried OldProof.testCard [missing-test-file] \(newProofs)"]),
	]

	static func test(function: String, in file: String = oldTests) -> String {
		#"{"file": "\#(file)", "function": "\#(function)"}"#
	}

	static func test(proof: String, _ method: String, in file: String = oldProofs) -> String {
		#"{"file": "\#(file)", "class": "\#(proof)", "method": "\#(method)"}"#
	}

	static func row(
		_ test: String, statement: String? = "S.", replacements: [String]? = nil,
		retiredBy: String? = nil
	) -> String {
		var members = [#""test": \#(test)"#]
		if let statement { members.append(#""statement": "\#(statement)""#) }
		if let replacements {
			members.append(#""replacements": [\#(replacements.joined(separator: ", "))]"#)
		}
		if let retiredBy { members.append(#""retiredBy": "\#(retiredBy)""#) }
		return "{" + members.joined(separator: ", ") + "}"
	}

	static func replacing(_ index: Int, with row: String) -> [String] {
		var rows = complete
		rows[index] = row
		return rows
	}

	func check() throws -> [String] {
		let path = "coverage/sample.json"
		let listed = files.map { #""\#($0)""# }.joined(separator: ", ")
		let table = #"""
			{"units": {"1.1": 1}, "criteria": [\#(Self.criterion)],
			"carried": {"files": [\#(listed)], "tests": [\#(rows.joined(separator: ","))]}}
			"""#
		return try Scratch(files: sources.merging([path: table]) { $1 }).inRoot { root in
			let found = Found()
			let problems = Problems { found.lines.append($0) }
			_ = try CoverageChecker(root: root, table: path, problems: problems).run()
			return found.lines
		}
	}
}

private final class Found {
	var lines: [String] = []
}
