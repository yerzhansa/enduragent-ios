import Foundation
import ToolSupport

enum CloseoutStage: String, Sendable, Decodable {
	case building, final
}

enum CloseoutStatus: String, Sendable {
	case met, deviation, open
}

struct CloseoutSection: Sendable, Equatable {
	let stage: CloseoutStage
	let rows: [CloseoutRow]
}

struct CloseoutRow: Sendable, Equatable {
	let id: String
	let group: RequirementGroup
	let status: CloseoutStatus
	let evidence: [EvidencePointer]
	let differences: [DifferencePointer]
	let waitsOn: [OpenReason]

	var json: JSONValue {
		.object([
			JSONMember(key: "id", value: .string(id)),
			JSONMember(key: "group", value: .string(group.rawValue)),
			JSONMember(key: "status", value: .string(status.rawValue)),
			JSONMember(key: "evidence", value: .array(evidence.map(\.json))),
			JSONMember(key: "differences", value: .array(differences.map(\.json))),
			JSONMember(key: "waitsOn", value: .array(waitsOn.map(\.json))),
		])
	}
}

enum TestName: Sendable, Equatable {
	case function(String)
	case method(class: String, method: String)
}

enum EvidencePointer: Sendable, Equatable, Decodable {
	case test(file: String, name: TestName)
	case criterion(table: String, id: String)
	case requirement(table: String, id: String)
	case phone(session: String, step: String)
	case record(String)
	case live(scenario: String)

	init(from decoder: any Decoder) throws {
		let (container, key) = try PointerKey.only(in: decoder)
		switch key.stringValue {
		case "test":
			let test = try container.decode(TestPayload.self, forKey: key)
			self = .test(file: test.file, name: try test.name(in: container, key))
		case "criterion":
			let row = try container.decode(RowPayload.self, forKey: key)
			self = .criterion(table: row.table, id: row.id)
		case "requirement":
			let row = try container.decode(RowPayload.self, forKey: key)
			self = .requirement(table: row.table, id: row.id)
		case "phone":
			let step = try container.decode(PhonePayload.self, forKey: key)
			self = .phone(session: step.session, step: step.step)
		case "record":
			self = .record(try container.decode(String.self, forKey: key))
		case "live":
			self = .live(scenario: try container.decode(LivePayload.self, forKey: key).scenario)
		default:
			throw PointerKey.unknown(key, in: container)
		}
	}

	var json: JSONValue {
		switch self {
		case .test(let file, .function(let function)):
			PointerKey.object("test", ["file": file, "function": function])
		case .test(let file, .method(let testClass, let method)):
			PointerKey.object("test", ["file": file, "class": testClass, "method": method])
		case .criterion(let table, let id):
			PointerKey.object("criterion", ["table": table, "id": id])
		case .requirement(let table, let id):
			PointerKey.object("requirement", ["table": table, "id": id])
		case .phone(let session, let step):
			PointerKey.object("phone", ["session": session, "step": step])
		case .record(let record):
			.object([JSONMember(key: "record", value: .string(record))])
		case .live(let scenario):
			PointerKey.object("live", ["scenario": scenario])
		}
	}
}

enum DifferencePointer: Sendable, Equatable, Decodable {
	case agreed(table: String, sub: String, record: String)
	case recorded(record: String, says: String)

	init(from decoder: any Decoder) throws {
		let (container, key) = try PointerKey.only(in: decoder)
		guard key.stringValue == "recorded" else { throw PointerKey.unknown(key, in: container) }
		let recorded = try container.decode(RecordedPayload.self, forKey: key)
		guard !recorded.says.contains(where: \.isNewline),
			recorded.says.contains(where: { !$0.isWhitespace })
		else {
			throw DecodingError.dataCorruptedError(
				forKey: key, in: container, debugDescription: "A recorded difference says one line")
		}
		self = .recorded(record: recorded.record, says: recorded.says)
	}

	var json: JSONValue {
		switch self {
		case .agreed(let table, let sub, let record):
			PointerKey.object("agreed", ["table": table, "sub": sub, "record": record])
		case .recorded(let record, let says):
			PointerKey.object("recorded", ["record": record, "says": says])
		}
	}
}

enum OpenReason: Sendable, Equatable, Decodable {
	case phone(session: String, step: String)
	case table(String, id: String)
	case work(String)

	init(from decoder: any Decoder) throws {
		let (container, key) = try PointerKey.only(in: decoder)
		switch key.stringValue {
		case "phone":
			let step = try container.decode(PhonePayload.self, forKey: key)
			self = .phone(session: step.session, step: step.step)
		case "table":
			let row = try container.decode(RowPayload.self, forKey: key)
			self = .table(row.table, id: row.id)
		case "work":
			let work = try container.decode(String.self, forKey: key)
			guard work.contains(where: { !$0.isWhitespace }) else {
				throw DecodingError.dataCorruptedError(
					forKey: key, in: container, debugDescription: "An open work reason names it")
			}
			self = .work(work)
		default:
			throw PointerKey.unknown(key, in: container)
		}
	}

	var json: JSONValue {
		switch self {
		case .phone(let session, let step):
			PointerKey.object("phone", ["session": session, "step": step])
		case .table(let table, let id):
			PointerKey.object("table", ["table": table, "id": id])
		case .work(let work):
			.object([JSONMember(key: "work", value: .string(work))])
		}
	}
}

struct HandEvidence: Sendable, Equatable, Decodable {
	static let path = "coverage/closeout/evidence.json"

	let stage: CloseoutStage
	let evidence: [String: [EvidencePointer]]
	let differences: [String: [DifferencePointer]]
	let waitsOn: [String: [OpenReason]]

	static func exists(root: String) -> Bool {
		FileManager.default.fileExists(atPath: NodePath.join(root, path))
	}

	static func load(root: String) throws -> HandEvidence {
		try JSONDecoder().decode(
			HandEvidence.self, from: FileSystem.read(NodePath.join(root, path)))
	}

	var keys: [(map: String, id: String)] {
		[
			("evidence", Array(evidence.keys)), ("differences", Array(differences.keys)),
			("waitsOn", Array(waitsOn.keys)),
		].flatMap { map, ids in ids.sorted().map { (map, $0) } }
	}
}

enum CloseoutDerivation {
	static func section(
		retained: RetainedRequirements, hand: HandEvidence, tables: [String: TableDigest]
	) -> CloseoutSection {
		let ordered = tables.keys.sorted().compactMap { path in tables[path].map { (path, $0) } }
		let approvals = Set(retained.approvals)
		let rows = retained.requirements.map { retainedID in
			let id = retainedID.id
			let evidence =
				ordered.flatMap { path, digest in
					digest.requirements.filter { $0.id == id && !approvals.contains(id) }.map {
						EvidencePointer.requirement(table: path, id: $0.id)
					}
				} + hand.evidence[id, default: []]
			let differences =
				ordered.flatMap { path, digest in
					digest.requirements.filter { reaches($0, id) }.map {
						DifferencePointer.agreed(
							table: path, sub: $0.id, record: $0.record ?? "none")
					}
				} + hand.differences[id, default: []]
			let waitsOn =
				ordered.flatMap { path, digest in
					digest.open.filter { $0 == id }.map { OpenReason.table(path, id: $0) }
				} + hand.waitsOn[id, default: []]
			let status: CloseoutStatus =
				!waitsOn.isEmpty ? .open : !differences.isEmpty ? .deviation : .met
			return CloseoutRow(
				id: id, group: retainedID.group, status: status, evidence: evidence,
				differences: differences, waitsOn: waitsOn)
		}
		return CloseoutSection(stage: hand.stage, rows: rows)
	}

	private static func reaches(_ row: RequirementDigest, _ id: String) -> Bool {
		guard row.agreedDifference != nil, let slash = row.id.firstIndex(of: "/") else {
			return false
		}
		if let reaches = row.reaches { return reaches.contains(id) }
		let parent = String(row.id[..<slash])
		return id == parent || id.hasPrefix(parent + ".")
	}
}

enum CloseoutLayout {
	static let opening = "\t\"closeout\": {"
	static let stagePrefix = "\t\t\"stage\": "
	static let rowsOpening = "\t\t\"rows\": ["
	static let rowIndent = "\t\t\t"
	static let rowsClosing = "\t\t]"
	static let closing = "\t}"
	static let openOpening = "\t\"open\": ["
	static let openCloserAlone = "\t]"
	static let openCloserBeforeSection = "\t],"

	static func written(_ section: CloseoutSection, into table: String) throws -> String {
		var lines = table.components(separatedBy: "\n")
		let written =
			[opening, stagePrefix + section.stage.rawValue.quotedAsJSON + ",", rowsOpening]
			+ section.rows.enumerated().map { index, row in
				rowIndent + line(row.json) + (index == section.rows.count - 1 ? "" : ",")
			} + [rowsClosing, closing]
		if let start = lines.firstIndex(of: opening) {
			guard let end = lines[start...].firstIndex(of: closing) else {
				throw CoverageFailure(description: "the closeout section has no closing line")
			}
			lines.replaceSubrange(start...end, with: written)
		} else {
			guard let last = lines.lastIndex(where: { !$0.isEmpty }), lines[last] == "}",
				last > 0, lines[last - 1] == openCloserAlone,
				lines[..<last].last(where: { $0.hasPrefix("\t\"") }) == openOpening
			else {
				throw CoverageFailure(
					description: "the table does not end with open on its own lines")
			}
			lines[last - 1] = openCloserBeforeSection
			lines.insert(contentsOf: written, at: last)
		}
		return lines.joined(separator: "\n")
	}

	static func line(_ value: JSONValue) -> String {
		switch value {
		case .object(let members):
			"{"
				+ members.map { $0.key.quotedAsJSON + ": " + line($0.value) }
				.joined(separator: ", ") + "}"
		case .array(let elements):
			"[" + elements.map(line).joined(separator: ", ") + "]"
		default:
			value.compactText
		}
	}
}

private struct PointerKey: CodingKey {
	let stringValue: String
	var intValue: Int? { nil }

	init(stringValue: String) {
		self.stringValue = stringValue
	}

	init?(intValue: Int) {
		nil
	}

	static func only(
		in decoder: any Decoder
	) throws -> (KeyedDecodingContainer<PointerKey>, PointerKey) {
		let container = try decoder.container(keyedBy: PointerKey.self)
		guard container.allKeys.count == 1, let key = container.allKeys.first else {
			throw DecodingError.dataCorrupted(
				DecodingError.Context(
					codingPath: decoder.codingPath,
					debugDescription: "A pointer is an object with exactly one key"))
		}
		return (container, key)
	}

	static func unknown(
		_ key: PointerKey, in container: KeyedDecodingContainer<PointerKey>
	) -> DecodingError {
		.dataCorruptedError(
			forKey: key, in: container, debugDescription: "\(key.stringValue) is not a pointer here"
		)
	}

	static func object(_ kind: String, _ fields: KeyValuePairs<String, String>) -> JSONValue {
		.object([
			JSONMember(
				key: kind,
				value: .object(fields.map { JSONMember(key: $0.key, value: .string($0.value)) }))
		])
	}
}

private struct TestPayload: Decodable {
	let file: String
	let function: String?
	let `class`: String?
	let method: String?

	func name(
		in container: KeyedDecodingContainer<PointerKey>, _ key: PointerKey
	) throws -> TestName {
		switch (function, `class`, method) {
		case (let function?, nil, nil):
			return .function(function)
		case (nil, let testClass?, let method?):
			return .method(class: testClass, method: method)
		default:
			throw DecodingError.dataCorruptedError(
				forKey: key, in: container,
				debugDescription: "A test names a function, or a class and a method")
		}
	}
}

private struct RowPayload: Decodable {
	let table: String
	let id: String
}

private struct PhonePayload: Decodable {
	let session: String
	let step: String
}

private struct LivePayload: Decodable {
	let scenario: String
}

private struct RecordedPayload: Decodable {
	let record: String
	let says: String
}
