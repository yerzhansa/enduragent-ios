@testable import EnduragentCoach

enum NpmKey: Sendable {
	case shown(as: String, NpmValue)
	case resolved(as: String, precedence: Int)
	case leftOut(String)

	static func measured(_ field: some ReadoutMeasurement) -> NpmKey {
		.shown(as: field.rawValue, .number)
	}
}

enum NpmValue: Sendable {
	case number
	case text
	case flag
	case identifier
	case list(renaming: [String: String])
	case count
	case ladderBounds
	case ladderNames

	func holds(_ value: JSONValue, shown: JSONValue?) -> Bool {
		switch self {
		case .number:
			return shown == value.numberValue.map(JSONValue.number)
		case .text:
			return shown == value.stringValue.map(JSONValue.string)
		case .flag:
			return shown == value.boolValue.map(JSONValue.bool)
		case .identifier:
			return shown
				== (value.stringValue ?? value.intValue().map(String.init)).map(JSONValue.string)
		case .list(let renaming):
			let entries = (value.arrayValue ?? []).map { entry in
				guard case .object(let fields) = entry else { return entry }
				return JSONValue.object(
					Dictionary(
						uniqueKeysWithValues: fields.compactMap { key, field in
							renaming[key].map { ($0, field) }
						}))
			}
			return shown == (entries.isEmpty ? nil : .array(entries))
		case .count:
			return shown?.arrayValue?.count == value.arrayValue?.count
		case .ladderBounds:
			let bounds = value.arrayValue ?? []
			let shownBounds =
				bounds.isEmpty || bounds.contains { $0.numberValue == nil } ? nil : bounds
			return shown?.arrayValue?.map { $0.objectFields["upTo"] ?? .null } == shownBounds
		case .ladderNames:
			let names = value.arrayValue ?? []
			return (shown?.arrayValue ?? []).enumerated().allSatisfy { index, zone in
				zone.objectFields["name"] == (index < names.count ? names[index] : nil)
			}
		}
	}
}

struct NpmProjectionAudit {
	let rules: [String: NpmKey]
	let phoneOnly: Set<String>

	init(_ rules: [String: NpmKey], phoneOnly: Set<String> = []) {
		self.rules = rules
		self.phoneOnly = phoneOnly
	}

	func unaccounted(in row: [String: JSONValue]) -> [String] {
		row.keys.filter { rules[$0] == nil }.sorted().map { "key \($0) has no account" }
	}

	func rows(
		_ npm: JSONValue, shown phone: [JSONValue]
	) -> (problems: [String], unmatched: [[String: JSONValue]]) {
		let key = "id"
		guard case .shown(let phoneKey, let value)? = rules[key] else {
			return (["rows are matched by \(key), which is not shown"], [])
		}
		var problems: [String] = []
		var unmatched: [[String: JSONValue]] = []
		var matched = 0
		for row in (npm.arrayValue ?? []).map(\.objectFields) {
			let label = row[key].map(canonicalJSON) ?? "a row without \(key)"
			let shown = row[key].flatMap { id in
				phone.map(\.objectFields).first {
					$0[phoneKey] != nil && value.holds(id, shown: $0[phoneKey])
				}
			}
			guard let shown else {
				problems += unaccounted(in: row).map { "\(label): \($0)" }
				unmatched.append(row)
				continue
			}
			matched += 1
			problems += Self.problems(in: [(self, row)], shown: shown).map { "\(label): \($0)" }
		}
		if matched != phone.count {
			problems.append("\(phone.count - matched) shown rows match no row of npm")
		}
		return (problems, unmatched)
	}

	static func problems(
		in sources: [(audit: NpmProjectionAudit, row: [String: JSONValue])],
		shown phone: [String: JSONValue]
	) -> [String] {
		var problems: [String] = []
		var explained = sources.reduce(into: Set<String>()) { $0.formUnion($1.audit.phoneOnly) }
		var precedence: [String: [(rank: Int, key: String, value: JSONValue)]] = [:]
		for (audit, row) in sources {
			problems += audit.unaccounted(in: row)
			for (key, value) in row.sorted(by: { $0.key < $1.key }) {
				switch audit.rules[key] {
				case nil:
					continue
				case .shown(let name, let kind)?:
					explained.insert(name)
					if !kind.holds(value, shown: phone[name]) {
						problems.append("\(key) is not shown as \(name)")
					}
				case .resolved(let name, let rank)?:
					explained.insert(name)
					precedence[name, default: []].append((rank, key, value))
				case .leftOut(let reason)?:
					if phone[key] != nil { problems.append("\(key) is shown, but \(reason)") }
				}
			}
		}
		for (name, sources) in precedence.sorted(by: { $0.key < $1.key }) {
			let first = sources.sorted { $0.rank < $1.rank }.first { $0.value != .null }
			if phone[name] != first?.value.numberValue.map(JSONValue.number) {
				problems.append("\(name) is not the first of \(sources.map(\.key)) npm sent")
			}
		}
		for name in phone.keys.sorted() where !explained.contains(name) {
			problems.append("\(name) is shown and no key of npm accounts for it")
		}
		return problems
	}
}
