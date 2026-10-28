import Foundation
import ToolSupport

struct CloseoutChecker {
	static let records = [
		"ADR-0080", "ADR-0081", "ADR-0082", "ADR-0083", "ADR-0084", "ADR-0085",
	]
	static let liveChecks = "apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachLiveChecks"
	static let section = "closeout"

	let root: String
	let table: JSONValue
	let problems: Problems
	private var sources: SourceFiles
	private var steps: [String: Set<String>] = [:]
	private var liveSources: [String]?

	init(root: String, table: JSONValue, problems: Problems) {
		self.root = root
		self.table = table
		self.problems = problems
		sources = SourceFiles(root: root)
	}

	mutating func run() throws {
		let committed = try table.member(Self.section)
		let declared: Bool
		if case .undefined = committed { declared = false } else { declared = true }
		guard declared || HandEvidence.exists(root: root) else { return }
		guard let retained = try RetainedRequirements.load(root: root) else {
			throw CoverageFailure(description: "the closeout needs \(RetainedRequirements.path)")
		}
		let hand = try HandEvidence.load(root: root)
		let sitting = try SittingRecord.load(root: root)
		let index = try CoverageIndex.load(root: root)
		let derived = CloseoutDerivation.section(
			retained: retained, hand: hand, tables: index.tables)
		let retainedIDs = Set(retained.requirements.map(\.id))
		for (map, id) in hand.keys where !retainedIDs.contains(id) {
			try problems.report(id, "hand-for-unretained", map)
		}
		if declared {
			try compare(committed, with: derived)
		} else {
			try problems.report(Self.section, "missing-closeout-section")
		}
		for row in derived.rows {
			try check(row, index: index)
		}
		if derived.stage == .final {
			try checkFinal(derived, index: index, sitting: sitting)
		}
	}

	private func compare(_ committed: JSONValue, with derived: CloseoutSection) throws {
		let stage = try committed.member("stage").text
		if stage != derived.stage.rawValue {
			try problems.report(
				Self.section, "stale-stage",
				"committed \(stage ?? "none"), \(HandEvidence.path) \(derived.stage.rawValue)")
		}
		var committedRows: [String: JSONValue] = [:]
		var committedOrder: [String] = []
		for (index, row) in try committed.member("rows").elements().enumerated() {
			guard let id = try row.member("id").text else {
				try problems.report("closeout row \(index + 1)", "no-identifier")
				continue
			}
			guard committedRows[id] == nil else {
				try problems.report(id, "duplicate-closeout-row")
				continue
			}
			committedRows[id] = row
			committedOrder.append(id)
		}
		let derivedIDs = Set(derived.rows.map(\.id))
		for id in committedOrder where !derivedIDs.contains(id) {
			try problems.report(id, "unknown-closeout-row")
		}
		for row in derived.rows {
			guard let committedRow = committedRows[row.id] else {
				try problems.report(row.id, "missing-closeout-row")
				continue
			}
			try compare(committedRow, with: row.json, row.id)
		}
	}

	private func compare(_ committed: JSONValue, with derived: JSONValue, _ id: String) throws {
		let derivedKeys = derived.entries.map(\.key)
		let fields = derivedKeys + committed.entries.map(\.key).filter { !derivedKeys.contains($0) }
		for field in fields
		where try Self.text(of: committed.member(field)) != Self.text(of: derived.member(field)) {
			try problems.report(id, "stale-row", field)
		}
	}

	private static func text(of value: JSONValue) -> String? {
		if case .undefined = value { return nil }
		return CloseoutLayout.line(value)
	}

	private mutating func check(_ row: CloseoutRow, index: CoverageIndex) throws {
		if row.evidence.isEmpty, row.differences.isEmpty, row.waitsOn.isEmpty {
			try problems.report(row.id, "no-evidence")
		}
		for pointer in row.evidence {
			try check(pointer, of: row, index: index)
		}
		for difference in row.differences {
			switch difference {
			case .agreed(_, _, let record), .recorded(let record, _):
				if !Self.records.contains(record) {
					try problems.report(row.id, "unknown-record", record)
				}
			}
		}
		for reason in row.waitsOn {
			switch reason {
			case .phone(let session, let step):
				try checkStep(session, step, of: row.id)
			case .table(let table, let id):
				guard let digest = try known(table, index, row.id) else { continue }
				if !digest.open.contains(id) {
					try problems.report(row.id, "open-reason-not-open", table, id)
				}
			case .work:
				break
			}
		}
	}

	private mutating func check(
		_ pointer: EvidencePointer, of row: CloseoutRow, index: CoverageIndex
	) throws {
		switch pointer {
		case .test(let file, let name):
			try sources.check(file, name, row.id, problems: problems)
		case .criterion(let table, let id):
			guard let digest = try known(table, index, row.id) else { return }
			switch digest.criteria[id] {
			case nil:
				try problems.report(row.id, "unknown-criterion-pointer", table, id)
			case .tested?, .phoneSession?:
				break
			case .noAutomatedProof?, .unproven?:
				try problems.report(row.id, "unproven-criterion-pointer", table, id)
			}
		case .requirement(let table, let id):
			guard let digest = try known(table, index, row.id) else { return }
			if digest.open.contains(id) {
				try problems.report(row.id, "open-requirement-pointer", table, id)
			} else if !digest.requirements.contains(where: { $0.id == id }) {
				try problems.report(row.id, "unknown-requirement-pointer", table, id)
			}
		case .phone(let session, let step):
			try checkStep(session, step, of: row.id)
		case .record(let record):
			if row.group != .decision {
				try problems.report(row.id, "record-off-decision", record)
			}
			if !Self.records.contains(record) {
				try problems.report(row.id, "unknown-record", record)
			}
		case .live(let scenario):
			if try !liveScenarioExists(scenario) {
				try problems.report(row.id, "unknown-live-scenario", scenario)
			}
		}
	}

	private func known(_ table: String, _ index: CoverageIndex, _ id: String) throws -> TableDigest?
	{
		guard let digest = index.tables[table] else {
			try problems.report(id, "unknown-table", table)
			return nil
		}
		return digest
	}

	private mutating func checkStep(_ session: String, _ step: String, of id: String) throws {
		if try !stepIDs(of: session).contains(step) {
			try problems.report(id, "unknown-phone-step", session, step)
		}
	}

	private mutating func stepIDs(of session: String) throws -> Set<String> {
		if let known = steps[session] { return known }
		let path = PhoneSessionPlan.path(root: root, name: session)
		guard !session.isEmpty, !session.contains("/"), !session.hasPrefix("."),
			FileManager.default.fileExists(atPath: path)
		else {
			steps[session] = []
			return []
		}
		let named = Set(try PhoneSessionPlan.load(path: path).steps.map(\.id))
		steps[session] = named
		return named
	}

	private mutating func liveScenarioExists(_ scenario: String) throws -> Bool {
		let texts = try liveSources ?? Self.swiftTexts(under: NodePath.join(root, Self.liveChecks))
		liveSources = texts
		let declaration = "name: \(scenario.quotedAsJSON)"
		return texts.contains { $0.contains(declaration) }
	}

	private static func swiftTexts(under folder: String) throws -> [String] {
		guard let files = FileManager.default.enumerator(atPath: folder) else { return [] }
		var texts: [String] = []
		while let file = files.nextObject() as? String {
			guard file.hasSuffix(".swift") else { continue }
			guard
				let text = String(
					validating: try FileSystem.read(NodePath.join(folder, file)), as: UTF8.self)
			else {
				throw CoverageFailure(description: "\(file) under \(liveChecks) is not UTF-8")
			}
			texts.append(text)
		}
		return texts
	}

	private func checkFinal(
		_ derived: CloseoutSection, index: CoverageIndex, sitting: SittingRecord
	) throws {
		for row in derived.rows {
			if row.status == .open {
				try problems.report(row.id, "open-at-closeout")
			}
			for case .phone(_, let step) in row.evidence {
				let verdict = sitting.steps[step]?.verdict
				if verdict != .pass {
					try problems.report(
						row.id, "phone-step-not-passed", step, verdict?.text ?? "no verdict")
				}
			}
		}
		for table in index.tables.keys.sorted() {
			for id in index.tables[table]?.open ?? [] {
				try problems.report(id, "open-at-closeout", table)
			}
		}
	}
}
