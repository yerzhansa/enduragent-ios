import Foundation
import ToolSupport

enum CriterionProof: Sendable, Equatable {
	case tested, phoneSession, noAutomatedProof, unproven

	init(row: JSONValue) throws {
		let listed = try row.member("tests")
		if listed.isTruthy, try !listed.elements().isEmpty {
			self = .tested
		} else if try row.member("phoneSession").text != nil {
			self = .phoneSession
		} else if try row.member("noAutomatedProof").text != nil {
			self = .noAutomatedProof
		} else {
			self = .unproven
		}
	}
}

struct RequirementDigest: Sendable, Equatable {
	let id: String
	let agreedDifference: String?
	let record: String?
	let reaches: [String]?

	init(row: JSONValue, id: String) throws {
		self.id = id
		agreedDifference = try row.member("agreedDifference").text
		record = agreedDifference.flatMap(Self.firstRecord)
		let listed = try row.member("reaches")
		reaches = listed.isTruthy ? try listed.elements().compactMap(\.text) : nil
	}

	private static func firstRecord(in text: String) -> String? {
		var rest = Substring(text)
		while let found = rest.range(of: "ADR-") {
			let digits = rest[found.upperBound...].prefix(4)
			if digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
				return "ADR-" + digits
			}
			rest = rest[found.upperBound...]
		}
		return nil
	}
}

struct TableDigest: Sendable {
	let criteria: [String: CriterionProof]
	let requirements: [RequirementDigest]
	let open: [String]

	init(declaredIn table: JSONValue) throws {
		var criteria: [String: CriterionProof] = [:]
		for row in try Self.rows(table.member("criteria")) {
			if let id = try row.member("id").text {
				criteria[id] = try CriterionProof(row: row)
			}
		}
		self.criteria = criteria
		requirements = try Self.rows(table.member("requirements")).compactMap { row in
			try row.member("id").text.map { try RequirementDigest(row: row, id: $0) }
		}
		open = try Self.rows(table.member("open")).compactMap(\.text)
	}

	private static func rows(_ section: JSONValue) throws -> [JSONValue] {
		if case .undefined = section { return [] }
		return try section.elements()
	}
}

struct CoverageIndex: Sendable {
	static let folder = "coverage"

	let tables: [String: TableDigest]

	static func load(root: String) throws -> CoverageIndex {
		let folder = NodePath.join(root, Self.folder)
		var tables: [String: TableDigest] = [:]
		for name in try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
		where name.hasSuffix(".json") {
			var isDirectory: ObjCBool = false
			let path = NodePath.join(folder, name)
			guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
				!isDirectory.boolValue
			else { continue }
			guard let text = String(validating: try FileSystem.read(path), as: UTF8.self) else {
				throw CoverageFailure(description: "\(Self.folder)/\(name) is not UTF-8")
			}
			tables[NodePath.join(Self.folder, name)] = try TableDigest(
				declaredIn: JSONValue.parse(text))
		}
		return CoverageIndex(tables: tables)
	}
}
