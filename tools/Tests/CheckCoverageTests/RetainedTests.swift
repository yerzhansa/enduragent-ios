import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

struct RetainedTests {
	static let specificationSHA256 =
		"998c7cad0f8e1bf075aa4aafd6672bbf621b764f614fe1f32d46aeeb3bc1413e"
	static let table = "coverage/milestone-6.json"
	static let minimalTable = #"""
		{"units": {"8.1": 1}, "criteria": [
			{"id": "8.1.1", "statement": "S.", "noAutomatedProof": "A count recorded in review."}
		]}
		"""#

	@Test(.timeLimit(.minutes(1)))
	func extractGivesEveryRetainedIdOnceWithItsMilestonesInAStableOrder() throws {
		let retained = try Self.extract(from: "specification.json", "decision.md")
		#expect(
			retained.requirements == [
				RetainedID(id: "B04.01", group: .work, milestones: [1, 2]),
				RetainedID(id: "B04.02", group: .work, milestones: [1, 2]),
				RetainedID(id: "B11.01", group: .work, milestones: [6]),
				RetainedID(id: "B11.02", group: .work, milestones: [6]),
				RetainedID(id: "B13.01", group: .work, milestones: [2]),
				RetainedID(id: "X01", group: .crossCutting, milestones: []),
				RetainedID(id: "X02", group: .crossCutting, milestones: []),
				RetainedID(id: "G01", group: .journey, milestones: []),
				RetainedID(id: "G02", group: .journey, milestones: []),
				RetainedID(id: "D01", group: .decision, milestones: []),
				RetainedID(id: "D02", group: .decision, milestones: []),
				RetainedID(id: "MOB01", group: .mobile, milestones: []),
				RetainedID(id: "MOB02", group: .mobile, milestones: []),
				RetainedID(id: "MOB10", group: .mobile, milestones: []),
			])
		#expect(retained.approvals == ["A01", "A02", "B01"])
	}

	@Test(.timeLimit(.minutes(1)))
	func agreedDifferencesAreTheBacktickedSubIdsThatStartTheItemsOfTheirSection() throws {
		let retained = try Self.extract(from: "specification.json", "decision.md")
		#expect(
			retained.differences
				== [
					"B10.02/no-snapshot", "B10.03/no-snapshot", "B11/three-outcomes",
					"G09/no-refresh",
				].map { AgreedDifference(sub: $0, record: "ADR-0085") })
	}

	@Test(.timeLimit(.minutes(1)))
	func aDecisionWithoutTheAgreedDifferencesSectionIsRefused() throws {
		let decision = try Self.fixture("decision.md").replacingOccurrences(
			of: "## Agreed differences from npm", with: "## Differences")
		let specification = try Self.fixture("specification.json")
		#expect(throws: CoverageFailure.self) {
			try RetainedRequirements.extract(
				specification: JSONValue.parse(specification),
				specificationBytes: Data(specification.utf8), decision: decision)
		}
	}

	@Test(.timeLimit(.minutes(1)))
	func approvalsAreTheApprovalIdsOfMilestoneFour() throws {
		let committed = try Self.committed()
		let milestoneFour = RequirementScope.milestoneFour.listed.filter {
			$0.count == 3 && "ABCD".contains($0.prefix(1)) && Int($0.dropFirst()) != nil
		}
		#expect(committed.approvals.count == 51)
		#expect(committed.approvals == milestoneFour.sorted())
	}

	@Test(
		.timeLimit(.minutes(1)),
		arguments: [
			Edit(from: #""id": "B11.02""#, to: #""id": "B11.03""#),
			Edit(from: #""sub": "G09/no-refresh""#, to: #""sub": "G09/refresh""#),
			Edit(from: #""A18""#, to: #""A19""#),
		])
	func aHandEditFailsCheckCoverage(_ edit: Edit) throws {
		let text = try Self.committedText()
		#expect(text.components(separatedBy: edit.from).count == 2)
		let edited = text.replacingOccurrences(of: edit.from, with: edit.to)
		let result = try Scratch(files: [
			RetainedRequirements.path: edited, Self.table: Self.minimalTable,
		]).runCommand(tables: [Self.table])
		#expect(result.status == 1)
		#expect(result.errors.count == 1)
		#expect(
			result.errors.first?.hasPrefix("retained.json [retained-digest-mismatch] committed ")
				== true)
	}

	@Test(.timeLimit(.minutes(1)))
	func theCommittedListPassesCheckCoverageUnedited() throws {
		let result = try Scratch(files: [
			RetainedRequirements.path: try Self.committedText(), Self.table: Self.minimalTable,
		]).runCommand(tables: [Self.table])
		#expect(result.errors == [])
		#expect(result.status == 0)
	}

	@Test(.timeLimit(.minutes(1)))
	func driftReportsEachChangeOnItsOwnLineAndFails() throws {
		let result = try Self.drift(
			writtenFrom: "specification.json", "decision.md",
			comparedWith: "specification-drifted.json", "decision-drifted.md")
		#expect(result.written == 0)
		#expect(result.drift.status == 1)
		#expect(
			result.drift.errors
				== [
					"added B13.02", "removed B04.02", "moved B13.01 from 2 to 2,3",
					"difference-added B10.04/no-history", "difference-removed G09/no-refresh",
				].map { "retained.json [retained-drift] \($0)" })
	}

	@Test(.timeLimit(.minutes(1)))
	func noDriftAfterWritingFromTheSameSources() throws {
		let result = try Self.drift(
			writtenFrom: "specification.json", "decision.md",
			comparedWith: "specification.json", "decision.md")
		#expect(result.written == 0)
		#expect(result.drift.errors == [])
		#expect(result.drift.status == 0)
	}

	@Test(.timeLimit(.minutes(1)))
	func committedListHoldsTheRetainedIdsOfTheSpecification() throws {
		let committed = try Self.committed()
		let groups = Dictionary(grouping: committed.requirements, by: \.group).mapValues(\.count)
		#expect(committed.requirements.count == 138)
		#expect(groups == [.work: 92, .crossCutting: 8, .journey: 10, .decision: 16, .mobile: 12])
		#expect(committed.differences.count == 9)
		#expect(committed.differences.allSatisfy { $0.record == "ADR-0085" })
		#expect(committed.approvals.count == 51)
		#expect(committed.digest.specification == Self.specificationSHA256)
		#expect(committed.digestMismatch == nil)
	}

	struct Edit: Sendable, CustomTestStringConvertible {
		let from: String
		let to: String

		var testDescription: String { "\(from) becomes \(to)" }
	}

	private static func drift(
		writtenFrom specification: String, _ decision: String,
		comparedWith newSpecification: String, _ newDecision: String
	) throws -> (written: Int32, drift: (status: Int32, output: [String], errors: [String])) {
		let names = [specification, decision, newSpecification, newDecision]
		let files = try Dictionary(
			names.map { ("sources/\($0)", try fixture($0)) }, uniquingKeysWith: { kept, _ in kept })
		return try Scratch(files: files).inRoot { root in
			let written = try Scratch.command(
				["--write-retained", "sources/\(specification)", "sources/\(decision)"], in: root)
			let drift = try Scratch.command(
				["--retained-drift", "sources/\(newSpecification)", "sources/\(newDecision)"],
				in: root)
			return (written.status, drift)
		}
	}

	private static func extract(
		from specification: String, _ decision: String
	) throws -> RetainedRequirements {
		let text = try fixture(specification)
		return try RetainedRequirements.extract(
			specification: JSONValue.parse(text), specificationBytes: Data(text.utf8),
			decision: try fixture(decision))
	}

	private static func fixture(_ name: String) throws -> String {
		let fixtures = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
		return try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
	}

	static func committed() throws -> RetainedRequirements {
		try #require(try RetainedRequirements.load(root: repository.path))
	}

	static func committedText() throws -> String {
		try String(
			contentsOf: repository.appendingPathComponent(RetainedRequirements.path),
			encoding: .utf8)
	}

	static var repository: URL {
		URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
	}
}
