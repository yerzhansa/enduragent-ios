import Foundation
import ToolSupport

@testable import CheckCoverage

struct CloseoutFixture: Sendable {
	static let table = "coverage/milestone-6.json"
	static let readTests = "Tests/ReadTests.swift"
	static let proofs = "UITests/ShortcutProofs.swift"
	static let tested =
		#"{"test": {"file": "Tests/ReadTests.swift", "function": "rangeIsRefused"}}"#
	static let checkerRetained: [RetainedID] = [
		RetainedID(id: "B04.01", group: .work, milestones: [1]),
		RetainedID(id: "B11.01", group: .work, milestones: [6]),
		RetainedID(id: "B11.02", group: .work, milestones: [6]),
		RetainedID(id: "B13.01", group: .work, milestones: [2]),
		RetainedID(id: "X03", group: .crossCutting, milestones: []),
		RetainedID(id: "G09", group: .journey, milestones: []),
		RetainedID(id: "D04", group: .decision, milestones: []),
		RetainedID(id: "MOB01", group: .mobile, milestones: []),
	]
	static let milestoneSix = #"""
		{
			"units": {
				"8.3": 1
			},
			"criteria": [
				{
					"id": "8.3.1",
					"statement": "S.",
					"tests": [
						{"file": "Tests/ReadTests.swift", "function": "rangeIsRefused"}
					]
				}
			],
			"requirements": [
				{
					"id": "B11.01",
					"statement": "S.",
					"criteria": ["8.3.1"]
				},
				{
					"id": "B11.02",
					"statement": "S.",
					"criteria": ["8.3.1"]
				},
				{
					"id": "B11/three-outcomes",
					"statement": "S.",
					"agreedDifference": "ADR-0085 records it.",
					"reaches": ["B11.01"]
				},
				{
					"id": "G09/no-refresh",
					"statement": "S.",
					"agreedDifference": "ADR-0085 records it."
				}
			],
			"plan": {
				"units": {
					"8.3": 1
				},
				"requirements": {
					"B11.01": ["8.3.1"],
					"B11.02": ["8.3.1"]
				}
			},
			"open": [
			]
		}

		"""#

	var retained = checkerRetained
	var differences = ["B11/three-outcomes", "G09/no-refresh"]
	var stage = "building"
	var handEvidence: [(id: String, pointers: String)] = [
		("B04.01", tested),
		(
			"B04.01",
			#"{"test": {"file": "UITests/ShortcutProofs.swift", "class": "ShortcutProof", "method": "testPick"}}"#
		),
		("B13.01", #"{"live": {"scenario": "review-deep"}}"#),
		("X03", #"{"criterion": {"table": "coverage/milestone-3.json", "id": "3.1.1"}}"#),
		("D04", #"{"record": "ADR-0085"}"#),
		("MOB01", #"{"phone": {"session": "closeout", "step": "closeout/lifecycle"}}"#),
	]
	var handDifferences: [(id: String, pointers: String)] = [
		("B13.01", #"{"recorded": {"record": "ADR-0080", "says": "The phone says it once."}}"#)
	]
	var waitsOn: [(id: String, pointers: String)] = []
	var verdicts: [String: String] = ["closeout/lifecycle": "pass"]
	var tables: [String: String] = [
		Self.table: milestoneSix,
		"coverage/milestone-3.json": #"""
		{"criteria": [
			{"id": "3.1.1", "tests": [{"file": "Tests/ReadTests.swift", "function": "rangeIsRefused"}]},
			{"id": "3.1.2", "phoneSession": "On the phone."},
			{"id": "3.1.3", "noAutomatedProof": "Counted in review."}
		]}
		"""#,
		"coverage/milestone-4.json": #"""
		{"criteria": [], "requirements": [{"id": "B17.01", "criteria": ["4.1.1"]}], "open": []}
		"""#,
	]
	var sources: [String: String] = [
		readTests: "struct ReadTests {\n\t@Test func rangeIsRefused() {}\n}\n",
		proofs: "final class ShortcutProof: XCTestCase {\n\tfunc testPick() {}\n}\n",
		NodePath.join(CloseoutChecker.liveChecks, "LiveCoachScenarios.swift"):
			"let deep = Scenario(\n\tname: \"review-deep\", turns: 2)\n",
		NodePath.join(PhoneSessionPlan.folder, "closeout.json"): #"""
		{"name": "closeout", "cap": 50, "ledger": "enduragent-m6/PHONE/messages.tsv", "steps": [
			{"id": "closeout/lifecycle", "driver": "operatorOnInstalledBuild", "planned": 0,
			 "setup": [], "checks": [{"look": "the app", "pass": "opens"}], "endsWith": "Open."}
		]}
		"""#,
	]

	func files() throws -> [String: String] {
		var files = tables.merging(sources) { $1 }
		files[RetainedRequirements.path] = try retainedText()
		files[HandEvidence.path] = handText()
		files[SittingRecord.path] =
			"{\"steps\": {"
			+ verdicts.sorted { $0.key < $1.key }.map {
				"\($0.key.quotedAsJSON): {\"verdict\": \($0.value.quotedAsJSON), \"date\": \"2026-11-02\"}"
			}.joined(separator: ", ") + "}}\n"
		return files
	}

	func run(
		writing: Bool = true, editing edit: (String) -> String = { $0 },
		arguments: [String] = []
	) throws -> (status: Int32, output: [String], errors: [String]) {
		try Scratch(files: files()).inRoot { root in
			if writing {
				let written = try Scratch.command(["--write-closeout", Self.table], in: root)
				guard written.status == 0 else { return written }
			}
			let path = NodePath.join(root, Self.table)
			let text = try String(contentsOfFile: path, encoding: .utf8)
			try Data(edit(text).utf8).write(to: URL(fileURLWithPath: path))
			return try Scratch.command(arguments + ["--root", root, Self.table], in: root)
		}
	}

	func written(
		rewritingWith later: CloseoutFixture? = nil, editing edit: (String) -> String = { $0 }
	) throws -> (original: String, first: String, second: String) {
		try Scratch(files: files()).inRoot { root in
			let path = NodePath.join(root, Self.table)
			let original = try String(contentsOfFile: path, encoding: .utf8)
			let first = try Self.writeCloseout(in: root)
			if let later {
				try Data(later.handText().utf8).write(
					to: URL(fileURLWithPath: NodePath.join(root, HandEvidence.path)))
			}
			try Data(edit(first).utf8).write(to: URL(fileURLWithPath: path))
			return (original, first, try Self.writeCloseout(in: root))
		}
	}

	private static func writeCloseout(in root: String) throws -> String {
		let result = try Scratch.command(["--write-closeout", table], in: root)
		guard result.status == 0, result.errors.isEmpty else {
			throw CoverageFailure(description: result.errors.joined(separator: "\n"))
		}
		return try String(contentsOfFile: NodePath.join(root, table), encoding: .utf8)
	}

	func section() throws -> CloseoutSection {
		try Scratch(files: files()).inRoot { root in
			guard let retained = try RetainedRequirements.load(root: root) else {
				throw CoverageFailure(description: "the fixture wrote no retained list")
			}
			return CloseoutDerivation.section(
				retained: retained, hand: try HandEvidence.load(root: root),
				tables: try CoverageIndex.load(root: root).tables)
		}
	}

	func handText() -> String {
		"{\"stage\": \(stage.quotedAsJSON), \"evidence\": \(Self.map(handEvidence)), "
			+ "\"differences\": \(Self.map(handDifferences)), \"waitsOn\": \(Self.map(waitsOn))}\n"
	}

	private static func map(_ entries: [(id: String, pointers: String)]) -> String {
		var order: [String] = []
		var grouped: [String: [String]] = [:]
		for entry in entries {
			if grouped[entry.id] == nil { order.append(entry.id) }
			grouped[entry.id, default: []].append(entry.pointers)
		}
		return "{"
			+ order.map {
				"\($0.quotedAsJSON): [\(grouped[$0, default: []].joined(separator: ", "))]"
			}
			.joined(separator: ", ") + "}"
	}

	private func retainedText() throws -> String {
		var packages: [String: [String]] = [:]
		var packageOrder: [String] = []
		var milestones: [Int: Set<String>] = [:]
		for row in retained where row.group == .work {
			let package = String(row.id.prefix { $0 != "." })
			if packages[package] == nil { packageOrder.append(package) }
			packages[package, default: []].append(row.id)
			for milestone in row.milestones { milestones[milestone, default: []].insert(package) }
		}
		func ids(_ group: RequirementGroup) -> [String] {
			retained.filter { $0.group == group }.map { "{\"id\": \($0.id.quotedAsJSON)}" }
		}
		let mobile = retained.filter { $0.group == .mobile }.map(\.id.quotedAsJSON)
		let crossCutting = retained.filter { $0.group == .crossCutting }.map(\.id).enumerated()
			.map { index, id in
				"{\"id\": \(id.quotedAsJSON), \"mobile_ids\": [\(index == 0 ? mobile.joined(separator: ", ") : "")]}"
			}
		let specification =
			"{\"packages\": ["
			+ packageOrder.map { package in
				"{\"id\": \(package.quotedAsJSON), \"work\": ["
					+ packages[package, default: []].map { "{\"id\": \($0.quotedAsJSON)}" }
					.joined(separator: ", ") + "]}"
			}.joined(separator: ", ") + "], \"milestones\": ["
			+ milestones.keys.sorted().map { number in
				"{\"id\": \"M\(number)\", \"packages\": ["
					+ milestones[number, default: []].sorted().map(\.quotedAsJSON)
					.joined(separator: ", ") + "]}"
			}.joined(separator: ", ") + "], \"cross_cutting\": ["
			+ crossCutting.joined(separator: ", ") + "], \"golden_journeys\": ["
			+ ids(.journey).joined(separator: ", ") + "], \"decisions\": ["
			+ ids(.decision).joined(separator: ", ")
			+ "], \"acceptance_traceability\": [{\"approval_ids\": [\"A01\"]}]}"
		let decision =
			"# Decision\n\n## Agreed differences from npm\n\n"
			+ differences.map { "- `\($0)`: it differs.\n" }.joined()
		return try RetainedRequirements.extract(
			specification: JSONValue.parse(specification),
			specificationBytes: Data(specification.utf8), decision: decision
		).encoded()
	}
}
