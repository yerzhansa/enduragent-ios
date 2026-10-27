import CryptoKit
import Foundation
import ToolSupport

enum RequirementGroup: String, Sendable, CaseIterable {
	case work, crossCutting, journey, decision, mobile
}

struct RetainedID: Sendable, Equatable {
	let id: String
	let group: RequirementGroup
	let milestones: [Int]
}

struct AgreedDifference: Sendable, Equatable {
	let sub: String
	let record: String
}

struct RetainedDigest: Sendable, Equatable {
	let lists: String
	let specification: String
	let decision: String
}

enum RetainedDrift: Sendable, Equatable {
	case added(String)
	case removed(String)
	case moved(String, from: [Int], to: [Int])
	case differenceAdded(String)
	case differenceRemoved(String)

	var line: String {
		switch self {
		case .added(let id):
			"added \(id)"
		case .removed(let id):
			"removed \(id)"
		case .moved(let id, let before, let after):
			"moved \(id) from \(Self.listed(before)) to \(Self.listed(after))"
		case .differenceAdded(let sub):
			"difference-added \(sub)"
		case .differenceRemoved(let sub):
			"difference-removed \(sub)"
		}
	}

	private static func listed(_ milestones: [Int]) -> String {
		milestones.isEmpty ? "none" : milestones.map(String.init).joined(separator: ",")
	}
}

struct RetainedRequirements: Sendable, Equatable {
	static let path = "coverage/spec/retained.json"
	static let record = "ADR-0085"
	static let differencesHeading = "## Agreed differences"

	let requirements: [RetainedID]
	let differences: [AgreedDifference]
	let approvals: [String]
	let digest: RetainedDigest

	static func extract(
		specification: JSONValue, specificationBytes: Data, decision: String
	) throws -> RetainedRequirements {
		let requirements = try retainedIDs(in: specification)
		let differences = try agreedDifferences(in: decision)
		let approvals = try Set(
			specification.member("acceptance_traceability").elements().flatMap {
				try $0.member("approval_ids").elements().map(identifier)
			}
		).sorted()
		return RetainedRequirements(
			requirements: requirements, differences: differences, approvals: approvals,
			digest: RetainedDigest(
				lists: canonicalDigest(requirements, differences, approvals),
				specification: sha256(specificationBytes), decision: sha256(Data(decision.utf8))))
	}

	static func load(root: String) throws -> RetainedRequirements? {
		let path = NodePath.resolve(root, Self.path)
		guard FileManager.default.fileExists(atPath: path) else { return nil }
		guard let text = String(validating: try FileSystem.read(path), as: UTF8.self) else {
			throw CoverageFailure(description: "\(Self.path) is not UTF-8")
		}
		return try RetainedRequirements(declaredIn: JSONValue.parse(text))
	}

	var summary: String {
		"\(requirements.count) requirements, \(differences.count) differences, \(approvals.count) approvals"
	}

	var digestMismatch: String? {
		let computed = Self.canonicalDigest(requirements, differences, approvals)
		guard computed != digest.lists else { return nil }
		return
			"retained.json [retained-digest-mismatch] committed \(digest.lists), computed \(computed)"
	}

	func encoded() -> String {
		let requirementRows = requirements.map { row in
			let milestones = row.milestones.map(String.init).joined(separator: ", ")
			return
				#"{"id": \#(row.id.quotedAsJSON), "group": \#(row.group.rawValue.quotedAsJSON), "#
				+ #""milestones": [\#(milestones)]}"#
		}
		let differenceRows = differences.map {
			#"{"sub": \#($0.sub.quotedAsJSON), "record": \#($0.record.quotedAsJSON)}"#
		}
		let lines =
			[
				"{", "\t\"sources\": {",
				"\t\t\"specification\": \(digest.specification.quotedAsJSON),",
				"\t\t\"decision\": \(digest.decision.quotedAsJSON)", "\t},",
				"\t\"digest\": \(digest.lists.quotedAsJSON),",
			] + Self.list("requirements", requirementRows, last: false)
			+ Self.list("differences", differenceRows, last: false)
			+ Self.list("approvals", approvals.map(\.quotedAsJSON), last: true) + ["}"]
		return lines.map { $0 + "\n" }.joined()
	}

	func drift(from committed: RetainedRequirements) -> [RetainedDrift] {
		let before = Dictionary(
			committed.requirements.map { ($0.id, $0.milestones) },
			uniquingKeysWith: { kept, _ in kept })
		let after = Set(requirements.map(\.id))
		let added = requirements.filter { before[$0.id] == nil }.map { RetainedDrift.added($0.id) }
		let removed = committed.requirements.filter { !after.contains($0.id) }.map {
			RetainedDrift.removed($0.id)
		}
		let moved = requirements.compactMap { row -> RetainedDrift? in
			guard let milestones = before[row.id], milestones != row.milestones else { return nil }
			return .moved(row.id, from: milestones, to: row.milestones)
		}
		let committedSubs = Set(committed.differences.map(\.sub))
		let freshSubs = Set(differences.map(\.sub))
		return added + removed + moved
			+ differences.filter { !committedSubs.contains($0.sub) }.map {
				RetainedDrift.differenceAdded($0.sub)
			}
			+ committed.differences.filter { !freshSubs.contains($0.sub) }.map {
				RetainedDrift.differenceRemoved($0.sub)
			}
	}

	private init(
		requirements: [RetainedID], differences: [AgreedDifference], approvals: [String],
		digest: RetainedDigest
	) {
		self.requirements = requirements
		self.differences = differences
		self.approvals = approvals
		self.digest = digest
	}

	private init(declaredIn file: JSONValue) throws {
		let sources = try file.member("sources")
		digest = RetainedDigest(
			lists: try Self.identifier(file.member("digest")),
			specification: try Self.identifier(sources.member("specification")),
			decision: try Self.identifier(sources.member("decision")))
		requirements = try file.member("requirements").elements().map { row in
			guard let group = try row.member("group").text.flatMap(RequirementGroup.init) else {
				throw CoverageFailure(description: "\(Self.path) names a group it does not know")
			}
			return RetainedID(
				id: try Self.identifier(row.member("id")), group: group,
				milestones: try row.member("milestones").elements().map(Self.milestone))
		}
		differences = try file.member("differences").elements().map { row in
			AgreedDifference(
				sub: try Self.identifier(row.member("sub")),
				record: try Self.identifier(row.member("record")))
		}
		approvals = try file.member("approvals").elements().map(Self.identifier)
	}

	private static func retainedIDs(in specification: JSONValue) throws -> [RetainedID] {
		var milestonesOfPackage: [String: Set<Int>] = [:]
		for milestone in try specification.member("milestones").elements() {
			let identifier = try identifier(milestone.member("id"))
			guard identifier.hasPrefix("M"), let number = Int(identifier.dropFirst()) else {
				throw CoverageFailure(description: "milestone \(identifier) is not numbered")
			}
			for package in try milestone.member("packages").elements() {
				milestonesOfPackage[try Self.identifier(package), default: []].insert(number)
			}
		}
		var work: [RetainedID] = []
		for package in try specification.member("packages").elements() {
			let milestones = milestonesOfPackage[try identifier(package.member("id")), default: []]
			for item in try package.member("work").elements() {
				work.append(
					RetainedID(
						id: try identifier(item.member("id")), group: .work,
						milestones: milestones.sorted()))
			}
		}
		let crossCutting = try specification.member("cross_cutting").elements()
		let named: [(RequirementGroup, [JSONValue])] = [
			(.crossCutting, try crossCutting.map { try $0.member("id") }),
			(
				.journey,
				try specification.member("golden_journeys").elements().map { try $0.member("id") }
			),
			(
				.decision,
				try specification.member("decisions").elements().map { try $0.member("id") }
			),
			(.mobile, try crossCutting.flatMap { try $0.member("mobile_ids").elements() }),
		]
		let others = try named.flatMap { group, identifiers in
			try identifiers.map { RetainedID(id: try identifier($0), group: group, milestones: []) }
		}
		var seen: Set<String> = []
		return RequirementGroup.allCases.flatMap { group in
			(work + others).filter { $0.group == group && seen.insert($0.id).inserted }
				.sorted { $0.id < $1.id }
		}
	}

	private static func agreedDifferences(in decision: String) throws -> [AgreedDifference] {
		let lines = decision.split(separator: "\n", omittingEmptySubsequences: false)
		guard let heading = lines.firstIndex(where: { $0.hasPrefix(differencesHeading) }) else {
			throw CoverageFailure(description: "the decision has no Agreed differences section")
		}
		return try lines[(heading + 1)...].prefix { !$0.hasPrefix("#") }
			.filter { $0.hasPrefix("- `") }
			.flatMap { try leadingSubIDs(of: $0.dropFirst(2)) }
			.map { AgreedDifference(sub: $0, record: record) }
	}

	private static func leadingSubIDs(of item: Substring) throws -> [String] {
		var rest = item
		var named: [String] = []
		while rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
			let sub = String(rest[rest.index(after: rest.startIndex)..<close])
			let parts = sub.split(separator: "/", omittingEmptySubsequences: false)
			guard parts.count == 2, !parts.contains(where: \.isEmpty),
				!sub.contains(where: \.isWhitespace)
			else {
				throw CoverageFailure(description: "the agreed difference `\(sub)` is not a sub-id")
			}
			named.append(sub)
			rest = rest[rest.index(after: close)...]
			guard let separator = [", and ", " and ", ", "].first(where: rest.hasPrefix) else {
				break
			}
			rest = rest.dropFirst(separator.count)
		}
		return named
	}

	private static func canonicalDigest(
		_ requirements: [RetainedID], _ differences: [AgreedDifference], _ approvals: [String]
	) -> String {
		let lines =
			requirements.map {
				(["requirement", $0.id, $0.group.rawValue] + $0.milestones.map(String.init))
					.joined(separator: " ")
			}
			+ differences.map { "difference \($0.sub) \($0.record)" }
			+ approvals.map { "approval \($0)" }
		return sha256(Data(lines.sorted().map { $0 + "\n" }.joined().utf8))
	}

	private static func sha256(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	private static func list(_ name: String, _ rows: [String], last: Bool) -> [String] {
		let closing = last ? "\t]" : "\t],"
		guard !rows.isEmpty else { return ["\t\(name.quotedAsJSON): []" + (last ? "" : ",")] }
		return ["\t\(name.quotedAsJSON): ["]
			+ rows.enumerated().map { index, row in
				"\t\t" + row + (index == rows.count - 1 ? "" : ",")
			} + [closing]
	}

	private static func identifier(_ value: JSONValue) throws -> String {
		guard let text = value.text else {
			throw CoverageFailure(description: "the retained list names an id that is not text")
		}
		return text
	}

	private static func milestone(_ value: JSONValue) throws -> Int {
		guard let number = value.number, let milestone = Int(exactly: number) else {
			throw CoverageFailure(description: "\(path) names a milestone that is not a number")
		}
		return milestone
	}
}
