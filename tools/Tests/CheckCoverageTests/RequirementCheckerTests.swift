import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

struct RequirementCheckerTests {
	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.unknownCriteria)
	func requirementRowNamesOnlyCriteriaOfItsTable(_ requirementCase: RequirementCase) throws {
		let problems = try requirementCase.check()
		#expect(problems == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.proofs)
	func requirementRowCarriesOneProofAndAnAgreedDifferenceOnlyOnAPart(
		_ requirementCase: RequirementCase
	) throws {
		let problems = try requirementCase.check()
		#expect(problems == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.scope)
	func openAndRowsAccountForTheRequirementsInScope(_ requirementCase: RequirementCase) throws {
		let problems = try requirementCase.check()
		#expect(problems == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.inScope)
	func everyRequirementInScopeIsOpenOrARow(_ identifier: String) throws {
		var requirementCase = RequirementCase(name: "\(identifier) is neither open nor a row")
		requirementCase.open.removeAll { $0 == identifier }
		requirementCase.rows.removeAll { $0.contains(#""id": "\#(identifier)""#) }
		let problems = try requirementCase.check()
		#expect(problems == ["\(identifier) [missing-requirement]"])
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.differences)
	func tableRecordsEveryAgreedDifferenceOfADR0083(_ requirementCase: RequirementCase) throws {
		let problems = try requirementCase.check()
		#expect(problems == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.plan)
	func unitsAndRequirementRowsKeepToThePlan(_ requirementCase: RequirementCase) throws {
		let problems = try requirementCase.check()
		#expect(problems == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.namedTests)
	func requirementReachesANamedTestUnlessItIsForThePhoneSessionOnly(
		_ requirementCase: RequirementCase
	) throws {
		let problems = try requirementCase.check()
		#expect(problems == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.sixReaches)
	func differenceWhoseParentIsNoRetainedIdNamesTheRetainedIdsItReaches(
		_ requirementCase: RequirementCase
	) throws {
		#expect(try requirementCase.check() == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.sixAgreed)
	func deletingAnAgreedDifferenceRowFromTheCommittedTableFails(_ identifier: String) throws {
		let table = "coverage/milestone-6.json"
		let lines = try String(
			contentsOf: RetainedTests.repository.appendingPathComponent(table), encoding: .utf8
		).components(separatedBy: "\n")
		let start = try #require(lines.firstIndex(of: "\t\t\t\"id\": \"\(identifier)\",")) - 1
		let end = try #require(lines[start...].firstIndex { $0.hasPrefix("\t\t}") })
		var kept = Array(lines[..<start] + lines[(end + 1)...])
		if lines[end] == "\t\t}" { kept[start - 1] = "\t\t}" }
		let root = try FileSystem.realPath(RetainedTests.repository.path)
		let problems = try Scratch(files: [table: kept.joined(separator: "\n")]).inRoot { scratch in
			let collected = Lines()
			_ = try CoverageChecker(
				root: root, table: NodePath.resolve(scratch, table),
				problems: Problems { collected.lines.append($0) }
			).run()
			return collected.lines
		}
		#expect(problems == ["\(identifier) [missing-agreed-difference]"])
	}

	@Test(
		.timeLimit(.minutes(1)),
		arguments: [
			#""requirements": [], "open": []"#,
			#""requirements": [], "plan": [], "open": []"#,
			#""requirements": [], "plan": {"requirements": {}}, "open": []"#,
			#""requirements": [], "plan": {"units": {"1.1": 2}}, "open": []"#,
			#""requirements": [], "plan": {"units": {"1.1": 2}, "requirements": {"A01": "1.1.1"}}, "open": []"#,
			#""requirements": [], "plan": {"units": {"1.1": 2}, "requirements": {"A01": [1]}}, "open": []"#,
			#""requirements": [], "plan": {"units": {"1.1": 2}, "requirements": {}}"#,
			#""requirements": {}, "plan": {"units": {"1.1": 2}, "requirements": {}}, "open": []"#,
		])
	func tableWhoseRequirementSectionsCannotBeReadStopsTheCommand(_ sections: String) throws {
		let table = #"{"units": {"1.1": 2}, "criteria": [], \#(sections)}"#
		let result = try Scratch(files: ["coverage/milestone-4.json": table])
			.runCommand(tables: ["coverage/milestone-4.json"])
		#expect(result.status == 2)
		#expect(result.output.isEmpty)
		#expect(result.errors.count == 1)
		#expect(
			result.errors.first?.hasPrefix(
				"check-coverage: coverage/milestone-4.json could not be read")
				== true)
	}
}

struct RequirementCase: Sendable, CustomTestStringConvertible {
	static let inScope = """
		B17.01 B17.02 B17.03 B17.04 B17.05 B17.06 B18.01 B18.02 B18.03 B18.04 B18.05 B18.06 B18.07 \
		B19.01 B19.02 B20.01 B20.02 B20.03 B20.04 B20.05 B21.01 B21.02 B21.03 B21.04 B21.05 \
		A01 A02 A03 A04 A05 A06 A07 A08 A09 A10 A11 A12 A13 A14 A15 A16 A17 A18 \
		B01 B02 B03 B04 B05 B06 B07 B08 B09 B10 B11 B12 B13 C01 C02 C03 C04 C05 C06 C07 C08 \
		D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 X01 X02 X04 X05 X06 G03 G04 G05 G06 G10
		""".split(separator: " ").map(String.init)
	static let agreed = [
		"B17.01/utc", "B17.06/head-unit", "B18.07/model-call", "B18.07/review-status",
		"B20.01/zones", "X04/zone", "X06/largest-text", "G06/midnight",
	]
	static let closed = closing("B17.01", ["1.1.1", "1.1.2"])
	static let baseRows = [closed] + agreed.map { difference($0) }
	static let basePlan = Dictionary(uniqueKeysWithValues: inScope.map { ($0, ["2.1.1"]) })
		.merging(["B17.01": ["1.1.1", "1.1.2"], "A01": ["1.1.1", "2.1.1"]]) { $1 }

	let name: String
	var path = "coverage/milestone-4.json"
	var rows = baseRows
	var open = inScope.filter { $0 != "B17.01" }
	var criteria = CoverageCase.complete
	var units = #"{"1.1": 2, "1.2": 1}"#
	var plannedUnits = #"{"1.1": 2, "1.2": 1, "2.1": 1}"#
	var planned = basePlan
	var problems: [String] = []
	var readsRetained = false

	var testDescription: String { name }

	static let unknownCriteria = [
		RequirementCase(
			name: "an open table with one closed requirement and every agreed difference"),
		RequirementCase(
			name: "a row names a planned criterion whose unit has no row yet",
			rows: baseRows + [closing("A01", ["1.1.1", "2.1.1"])],
			open: inScope.filter { !["B17.01", "A01"].contains($0) },
			problems: ["A01 [unknown-criterion] 2.1.1"]),
	]

	static let proofs = [
		RequirementCase(
			name: "a part lists criteria and an agreed difference",
			rows: baseRows + [
				proof(
					"B17.02/part", #""criteria": ["2.1.1"], "agreedDifference": "ADR-0083 agrees.""#
				)
			],
			problems: ["B17.02/part [more-than-one-proof]"]),
		RequirementCase(
			name: "a row has neither criteria nor an agreed difference",
			rows: replacing("B17.01", with: proof("B17.01", #""phoneSessionOnly": "A phone.""#)),
			problems: ["B17.01 [no-proof]"]),
		RequirementCase(
			name: "a row has an empty criteria list and an empty agreed difference",
			rows: replacing(
				"B17.01", with: proof("B17.01", #""criteria": [], "agreedDifference": """#)),
			problems: ["B17.01 [no-proof]"]),
		RequirementCase(
			name: "an agreed difference names another decision",
			rows: replacing(
				"X04/zone", with: difference("X04/zone", "ADR-0082 keeps the phone's day.")),
			problems: ["X04/zone [difference-without-adr]"]),
		RequirementCase(
			name: "an agreed difference closes a parent",
			rows: baseRows + [difference("B17.06")],
			open: inScope.filter { !["B17.01", "B17.06"].contains($0) },
			problems: ["B17.06 [difference-on-parent]"]),
		RequirementCase(
			name: "an agreed difference belongs to the requirement that waits for Milestone 5",
			rows: baseRows + [difference("B19.03/plan-save")],
			problems: ["B19.03/plan-save [unknown-parent]"]),
		RequirementCase(
			name: "a sub-id has a parent of no milestone",
			rows: baseRows + [difference("Z01/part")],
			problems: ["Z01/part [unknown-parent]"]),
		RequirementCase(
			name: "a sub-id names no part, or two",
			rows: baseRows + [difference("B17.06/"), difference("B17.06/head/unit")],
			problems: ["B17.06/ [unknown-requirement]", "B17.06/head/unit [unknown-requirement]"]),
		RequirementCase(
			name: "a row has no statement",
			rows: replacing("B17.01", with: #"{"id": "B17.01", "criteria": ["1.1.1", "1.1.2"]}"#),
			problems: ["B17.01 [no-statement]"]),
	]

	static let scope =
		[
			RequirementCase(
				name: "a closed requirement is still open",
				open: inScope,
				problems: ["B17.01 [closed-but-open]"]),
			RequirementCase(
				name: "a requirement is closed twice",
				rows: baseRows + [closed],
				problems: ["B17.01 [duplicate-requirement]"]),
			RequirementCase(
				name: "a row has no id",
				rows: baseRows + [#"{"statement": "S.", "criteria": ["1.1.1"]}"#],
				problems: ["requirement \(baseRows.count + 1) [no-identifier]"]),
			RequirementCase(
				name: "an open entry is not an id",
				open: inScope.filter { $0 != "B17.01" } + [""],
				problems: ["open 86 [no-identifier]"]),
			RequirementCase(
				name: "the requirement that waits for Milestone 5 is closed",
				rows: baseRows + [closing("B19.03", ["1.1.1"])],
				problems: ["B19.03 [unknown-requirement]"]),
			RequirementCase(
				name: "an agreed difference is also open",
				open: inScope.filter { $0 != "B17.01" } + ["B20.01/zones"],
				problems: ["B20.01/zones [closed-but-open]"]),
		]
		+ [
			"B19.03", "B17.07", "B18.08", "B20.06", "B21.06", "A19", "B14", "C09", "D13", "X03",
			"G07", "b17.01",
		]
		.map { identifier in
			RequirementCase(
				name: "\(identifier) is outside the milestone",
				open: inScope.filter { $0 != "B17.01" } + [identifier],
				problems: ["\(identifier) [unknown-requirement]"])
		}

	static let differences =
		agreed.map { identifier in
			RequirementCase(
				name: "\(identifier) has no row",
				rows: baseRows.filter { !$0.contains(#""id": "\#(identifier)""#) },
				problems: ["\(identifier) [missing-agreed-difference]"])
		} + [
			RequirementCase(
				name: "an agreed difference is proved by criteria instead",
				rows: replacing("B20.01/zones", with: closing("B20.01/zones", ["1.1.1"])),
				planned: basePlan.merging(["B20.01/zones": ["1.1.1"]]) { $1 },
				problems: ["B20.01/zones [missing-agreed-difference]"]),
			RequirementCase(
				name: "an agreed difference does not close its parent",
				open: inScope.filter { !["B17.01", "B20.01"].contains($0) },
				problems: ["B20.01 [missing-requirement]"]),
		]

	static let plan = [
		RequirementCase(
			name: "a unit declares fewer criteria than its plan",
			plannedUnits: #"{"1.1": 3, "1.2": 1, "2.1": 1}"#,
			problems: ["1.1 [below-plan] declares 2 of 3"]),
		RequirementCase(
			name: "a unit is not in the plan",
			plannedUnits: #"{"1.1": 2, "2.1": 1}"#,
			problems: ["1.2 [unplanned-unit]"]),
		RequirementCase(
			name: "a planned requirement names a criterion past its unit's plan",
			planned: basePlan.merging(["A01": ["1.1.1", "2.1.2"]]) { $1 },
			problems: ["A01 [unplanned-criterion] 2.1.2"]),
		RequirementCase(
			name: "a requirement in scope has no plan",
			planned: basePlan.filter { $0.key != "G10" },
			problems: ["G10 [unplanned-requirement]"]),
		RequirementCase(
			name: "a row leaves out a planned criterion",
			rows: replacing("B17.01", with: closing("B17.01", ["1.1.1"])),
			problems: ["B17.01 [differs-from-plan] planned 1.1.1, 1.1.2"]),
		RequirementCase(
			name: "a row names a criterion the plan does not give it",
			rows: replacing("B17.01", with: closing("B17.01", ["1.1.1", "1.1.2", "1.2.1"])),
			problems: ["B17.01 [differs-from-plan] planned 1.1.1, 1.1.2"]),
		RequirementCase(
			name: "a row names a planned criterion twice in place of another",
			rows: baseRows + [closing("A01", ["1.1.1", "1.1.1"])],
			open: inScope.filter { !["B17.01", "A01"].contains($0) },
			planned: basePlan.merging(["A01": ["1.1.1", "1.1.2"]]) { $1 },
			problems: ["A01 [differs-from-plan] planned 1.1.1, 1.1.2"]),
		RequirementCase(
			name: "a row lists its planned criteria in another order",
			rows: replacing("B17.01", with: closing("B17.01", ["1.1.2", "1.1.1"]))),
		RequirementCase(
			name: "a sub-id with criteria has no plan",
			rows: baseRows + [closing("B17.02/part", ["1.1.1"])],
			problems: ["B17.02/part [differs-from-plan] planned none"]),
	]

	static let namedTests = [
		RequirementCase(
			name: "every criterion of a row waits for the phone session",
			rows: baseRows + [closing("B17.02", ["1.2.1"])],
			open: inScope.filter { !["B17.01", "B17.02"].contains($0) },
			planned: basePlan.merging(["B17.02": ["1.2.1"]]) { $1 },
			problems: ["B17.02 [no-named-test]"]),
		RequirementCase(
			name: "every criterion of a row has no automated proof",
			rows: baseRows + [closing("B17.02", ["1.2.1"])],
			open: inScope.filter { !["B17.01", "B17.02"].contains($0) },
			criteria: Array(CoverageCase.complete.prefix(2)) + [
				#"{"id": "1.2.1", "statement": "S.", "noAutomatedProof": "Types."}"#
			],
			planned: basePlan.merging(["B17.02": ["1.2.1"]]) { $1 },
			problems: ["B17.02 [no-named-test]"]),
		RequirementCase(
			name: "a row whose criteria wait for the phone session says why",
			rows: baseRows + [
				proof(
					"B17.02",
					#""criteria": ["1.2.1"], "phoneSessionOnly": "Only the operator's phone has a head unit.""#
				)
			],
			open: inScope.filter { !["B17.01", "B17.02"].contains($0) },
			planned: basePlan.merging(["B17.02": ["1.2.1"]]) { $1 }),
		RequirementCase(
			name: "a row whose criteria wait for the phone session gives an empty reason",
			rows: baseRows + [proof("B17.02", #""criteria": ["1.2.1"], "phoneSessionOnly": """#)],
			open: inScope.filter { !["B17.01", "B17.02"].contains($0) },
			planned: basePlan.merging(["B17.02": ["1.2.1"]]) { $1 },
			problems: ["B17.02 [no-named-test]"]),
		RequirementCase(
			name: "one criterion of a row has a named test",
			rows: baseRows + [closing("B17.02", ["1.2.1", "1.1.1"])],
			open: inScope.filter { !["B17.01", "B17.02"].contains($0) },
			planned: basePlan.merging(["B17.02": ["1.1.1", "1.2.1"]]) { $1 }),
	]

	static func proof(_ identifier: String, _ members: String) -> String {
		#"{"id": "\#(identifier)", "statement": "S.", \#(members)}"#
	}

	static func closing(_ identifier: String, _ criteria: [String]) -> String {
		proof(identifier, #""criteria": [\#(criteria.map(quoted).joined(separator: ", "))]"#)
	}

	static func quoted(_ text: String) -> String {
		"\"\(text)\""
	}

	static func difference(
		_ identifier: String, _ sentence: String = "ADR-0083 makes the phone's day today."
	) -> String {
		proof(identifier, #""agreedDifference": "\#(sentence)""#)
	}

	static func replacing(_ identifier: String, with row: String) -> [String] {
		baseRows.map { $0.contains(#""id": "\#(identifier)""#) ? row : $0 }
	}

	func check() throws -> [String] {
		let plannedRequirements = planned.sorted { $0.key < $1.key }.map { identifier, criteria in
			"\(Self.quoted(identifier)): [\(criteria.map(Self.quoted).joined(separator: ", "))]"
		}
		let table = """
			{"units": \(units), "criteria": [\(criteria.joined(separator: ","))],
			"requirements": [\(rows.joined(separator: ","))],
			"plan": {"units": \(plannedUnits), "requirements": {\(plannedRequirements.joined(separator: ", "))}},
			"open": [\(open.map(Self.quoted).joined(separator: ", "))]}
			"""
		let retained =
			readsRetained ? [RetainedRequirements.path: try RetainedTests.committedText()] : [:]
		let files = CoverageCase.sources.merging(retained) { $1 }.merging([path: table]) { $1 }
		return try Scratch(files: files).inRoot {
			root in
			let lines = Lines()
			let problems = Problems { lines.lines.append($0) }
			_ = try CoverageChecker(root: root, table: path, problems: problems).run()
			return lines.lines
		}
	}
}

private final class Lines {
	var lines: [String] = []
}
