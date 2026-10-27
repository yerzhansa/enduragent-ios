import Foundation

package enum JournalLine: Sendable, Equatable, Codable {
	case problem(ProblemLine)
	case usage(UsageLine)

	private enum Key: String, CodingKey {
		case problem
		case usage
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		let problem = try container.decodeIfPresent(ProblemLine.self, forKey: .problem)
		let usage = try container.decodeIfPresent(UsageLine.self, forKey: .usage)
		switch (problem, usage) {
		case (let problem?, nil): self = .problem(problem)
		case (nil, let usage?): self = .usage(usage)
		default:
			throw DecodingError.dataCorrupted(
				.init(
					codingPath: container.codingPath,
					debugDescription: "A journal line holds exactly one of problem and usage."))
		}
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		switch self {
		case .problem(let problem): try container.encode(problem, forKey: .problem)
		case .usage(let usage): try container.encode(usage, forKey: .usage)
		}
	}
}

package struct StampedLine: Sendable, Equatable, Codable {
	package let at: Date
	package let line: JournalLine

	private enum Key: String, CodingKey {
		case at
	}

	package init(at: Date, line: JournalLine) {
		self.at = JournalTime.date(milliseconds: JournalTime.milliseconds(of: at))
		self.line = line
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		let stamp = try container.decode(String.self, forKey: .at)
		guard let milliseconds = JournalTime.milliseconds(parsing: stamp) else {
			throw DecodingError.dataCorruptedError(
				forKey: .at, in: container, debugDescription: "The time is not an ISO 8601 stamp.")
		}
		at = JournalTime.date(milliseconds: milliseconds)
		line = try JournalLine(from: decoder)
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		try container.encode(JournalTime.stamp(JournalTime.milliseconds(of: at)), forKey: .at)
		try line.encode(to: encoder)
	}

	package func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}

	package init(decoding line: Data) throws {
		self = try JSONDecoder().decode(Self.self, from: line)
	}
}

private enum JournalTime {
	static func milliseconds(of date: Date) -> Int64 {
		Int64((date.timeIntervalSince1970 * 1_000).rounded())
	}

	static func date(milliseconds: Int64) -> Date {
		Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
	}

	static func stamp(_ milliseconds: Int64) -> String {
		let fraction = (milliseconds % 1_000 + 1_000) % 1_000
		let seconds = (milliseconds - fraction) / 1_000
		let whole = Date(timeIntervalSince1970: Double(seconds)).formatted(.iso8601)
		return whole.dropLast() + "." + String(1_000 + fraction).dropFirst() + "Z"
	}

	static func milliseconds(parsing stamp: String) -> Int64? {
		let parts = stamp.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 2, parts[1].count == 4, parts[1].hasSuffix("Z"),
			parts[1].dropLast().allSatisfy({ $0.isASCII && $0.isNumber }),
			let fraction = Int64(parts[1].dropLast())
		else { return nil }
		guard let whole = ISO8601DateFormatter().date(from: parts[0] + "Z"),
			let seconds = Int64(exactly: whole.timeIntervalSince1970.rounded())
		else { return nil }
		return seconds * 1_000 + fraction
	}
}

package struct ProblemLine: Sendable, Equatable, Codable {
	package let kind: ProblemKind
	package let subject: ProblemSubject?
	package let cause: ProblemCode?
	package let detail: ProblemCode?
	package let row: SkippedRowText?

	package init(
		_ kind: ProblemKind, subject: ProblemSubject? = nil, cause: ProblemCode? = nil,
		detail: ProblemCode? = nil, row: SkippedRowText? = nil
	) {
		self.kind = kind
		self.subject = subject
		self.cause = cause
		self.detail = detail
		self.row = row
	}
}

package struct SkippedRowText: Sendable, Equatable, Codable {
	package let kind: ScrubbedText
	package let ulid: ScrubbedText

	package init(kind: ScrubbedText, ulid: ScrubbedText) {
		self.kind = kind
		self.ulid = ulid
	}
}

package struct ProblemCode: Sendable, Hashable, Codable {
	package static let limit = 128

	package let rawValue: String

	package init(_ name: StaticString) {
		rawValue = "\(name)"
	}

	package init(_ name: StaticString, _ number: Int) {
		rawValue = "\(name)(\(number))"
	}

	package init<Code: RawRepresentable & CaseIterable>(caseOf code: Code)
	where Code.RawValue == String {
		rawValue = String(describing: code)
	}

	private init(joining head: String, _ tail: String) {
		let cut = (head + "." + tail).prefix(Self.limit)
		guard let open = cut.lastIndex(of: "("), !cut[open...].contains(")") else {
			rawValue = String(cut)
			return
		}
		rawValue = String(cut[..<open])
	}

	package func then(_ next: ProblemCode) -> ProblemCode {
		ProblemCode(joining: rawValue, next.rawValue)
	}

	package func then(_ type: ErrorTypeName) -> ProblemCode {
		ProblemCode(joining: rawValue, type.value)
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let raw = try container.decode(String.self)
		guard Self.isClosed(raw) else {
			throw DecodingError.dataCorruptedError(
				in: container, debugDescription: "The value is not a problem code."
			)
		}
		rawValue = raw
	}

	package func encode(to encoder: any Encoder) throws {
		guard Self.isClosed(rawValue) else {
			throw EncodingError.invalidValue(
				rawValue,
				.init(
					codingPath: encoder.codingPath,
					debugDescription: "The value is not a problem code."))
		}
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	private static func isClosed(_ raw: String) -> Bool {
		let shape = #/[A-Za-z][A-Za-z0-9.]*(?:\(-?[0-9]{1,20}\)[A-Za-z0-9.]*)*/#
			.matchingSemantics(.unicodeScalar)
		return raw.unicodeScalars.count <= limit && raw.wholeMatch(of: shape) != nil
	}
}

package enum ProblemSubject: Sendable, Equatable, Codable {
	case attempt(ULID)
	case turn(ULID)
	case chat(ChatRef)
	case slot(CredentialSlotCode)
	case confirmation(ULID)

	private enum Key: String, CodingKey {
		case attempt
		case turn
		case chat
		case slot
		case confirmation
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: Key.self)
		guard container.allKeys.count == 1, let key = container.allKeys.first else {
			throw DecodingError.dataCorrupted(
				.init(
					codingPath: container.codingPath,
					debugDescription: "A subject names exactly one thing."))
		}
		switch key {
		case .attempt: self = .attempt(try container.decodeULID(forKey: key))
		case .turn: self = .turn(try container.decodeULID(forKey: key))
		case .chat: self = .chat(try container.decode(ChatRef.self, forKey: key))
		case .slot: self = .slot(try container.decode(CredentialSlotCode.self, forKey: key))
		case .confirmation: self = .confirmation(try container.decodeULID(forKey: key))
		}
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		switch self {
		case .attempt(let ulid): try container.encode(ulid.rawValue, forKey: .attempt)
		case .turn(let ulid): try container.encode(ulid.rawValue, forKey: .turn)
		case .chat(let chat): try container.encode(chat, forKey: .chat)
		case .slot(let slot): try container.encode(slot, forKey: .slot)
		case .confirmation(let ulid): try container.encode(ulid.rawValue, forKey: .confirmation)
		}
	}
}

extension KeyedDecodingContainer {
	func decodeULID(forKey key: Key) throws -> ULID {
		guard let ulid = ULID(rawValue: try decode(String.self, forKey: key)) else {
			throw DecodingError.dataCorruptedError(
				forKey: key, in: self, debugDescription: "The value is not a ULID.")
		}
		return ulid
	}
}

package struct ChatRef: Sendable, Equatable, Codable {
	package let rawValue: String

	package init?(_ chat: ChatID) {
		guard Self.isRef(chat.rawValue) else { return nil }
		rawValue = chat.rawValue
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let raw = try container.decode(String.self)
		guard Self.isRef(raw) else {
			throw DecodingError.dataCorruptedError(
				in: container, debugDescription: "The value is not a conversation id.")
		}
		rawValue = raw
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	private static func isRef(_ raw: String) -> Bool {
		(1...40).contains(raw.unicodeScalars.count)
			&& raw.unicodeScalars.allSatisfy {
				("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
					|| $0 == "-"
			}
	}
}

package struct CredentialSlotCode: Sendable, Equatable, Codable {
	package let rawValue: String

	package init(_ slot: CredentialSlot) {
		rawValue = slot.rawValue
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		guard let slot = CredentialSlot(rawValue: try container.decode(String.self)) else {
			throw DecodingError.dataCorruptedError(
				in: container, debugDescription: "The value is not a credential slot.")
		}
		self.init(slot)
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}
