struct JSONFailure: Error, CustomStringConvertible {
	let description: String
}

struct JSONMember {
	let key: String
	var value: JSONValue
}

indirect enum JSONValue {
	case undefined
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([JSONMember])

	static func parse(_ text: String) throws -> JSONValue {
		var reader = JSONReader(bytes: Array(text.utf8))
		return try reader.document()
	}

	var isTruthy: Bool {
		switch self {
		case .undefined, .null:
			false
		case .bool(let value):
			value
		case .number(let value):
			value != 0
		case .string(let value):
			!value.isEmpty
		case .array, .object:
			true
		}
	}

	var entries: [JSONMember] {
		switch self {
		case .object(let members):
			members
		case .array(let elements):
			elements.enumerated().map { JSONMember(key: String($0.offset), value: $0.element) }
		default:
			[]
		}
	}

	func isString(_ text: String) -> Bool {
		guard case .string(let value) = self else { return false }
		return value.unicodeScalars.elementsEqual(text.unicodeScalars)
	}

	func isSamePrimitive(as other: JSONValue) -> Bool {
		switch (self, other) {
		case (.undefined, .undefined), (.null, .null):
			true
		case (.bool(let left), .bool(let right)):
			left == right
		case (.number(let left), .number(let right)):
			left == right
		case (.string(let left), .string):
			other.isString(left)
		default:
			false
		}
	}

	func member(_ name: String) throws -> JSONValue {
		switch self {
		case .undefined, .null:
			throw JSONFailure(description: "Cannot read \(name) of a missing value")
		case .object(let members):
			return members.first { $0.key.unicodeScalars.elementsEqual(name.unicodeScalars) }?.value
				?? .undefined
		case .array(let elements):
			guard JSONReader.isArrayIndex(name), let index = Int(name), index < elements.count
			else {
				return .undefined
			}
			return elements[index]
		default:
			return .undefined
		}
	}

	func member(_ key: JSONValue) throws -> JSONValue {
		try member(key.propertyKey())
	}

	func elements() throws -> [JSONValue] {
		guard case .array(let elements) = self else {
			throw JSONFailure(description: "Expected a list")
		}
		return elements
	}

	private func propertyKey() throws -> String {
		switch self {
		case .undefined:
			return "undefined"
		case .null:
			return "null"
		case .bool(let value):
			return value ? "true" : "false"
		case .string(let value):
			return value
		case .number(let value):
			guard let whole = Int64(exactly: value), abs(whole) < 1 << 53 else {
				throw JSONFailure(description: "Cannot use the number \(value) as a name")
			}
			return String(whole)
		case .array, .object:
			throw JSONFailure(description: "Cannot use a list or a group as a name")
		}
	}
}

struct JSONReader {
	private static let quote = UInt8(ascii: "\"")
	private static let backslash = UInt8(ascii: "\\")

	let bytes: [UInt8]
	private var position = 0

	init(bytes: [UInt8]) {
		self.bytes = bytes
	}

	static func isArrayIndex(_ key: String) -> Bool {
		let digits = key.utf8
		guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy(isDigit) else { return false }
		guard digits.first != UInt8(ascii: "0") || digits.count == 1, let index = UInt64(key) else {
			return false
		}
		return index < 4_294_967_295
	}

	private static func isDigit(_ byte: UInt8) -> Bool {
		byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
	}

	mutating func document() throws -> JSONValue {
		let value = try value()
		skipWhitespace()
		guard position == bytes.count else { throw failure }
		return value
	}

	private var next: UInt8? {
		position < bytes.count ? bytes[position] : nil
	}

	private var failure: JSONFailure {
		JSONFailure(description: "Invalid JSON at byte \(position)")
	}

	private mutating func skipWhitespace() {
		while position < bytes.count {
			let byte = bytes[position]
			guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D else { return }
			position += 1
		}
	}

	private mutating func take() throws -> UInt8 {
		guard let byte = next else { throw failure }
		position += 1
		return byte
	}

	private mutating func value() throws -> JSONValue {
		skipWhitespace()
		switch next {
		case Self.quote:
			return .string(try string())
		case UInt8(ascii: "{"):
			return .object(try members())
		case UInt8(ascii: "["):
			return .array(try elements())
		case UInt8(ascii: "t"):
			return try word("true", .bool(true))
		case UInt8(ascii: "f"):
			return try word("false", .bool(false))
		case UInt8(ascii: "n"):
			return try word("null", .null)
		default:
			return .number(try number())
		}
	}

	private mutating func word(_ word: String, _ value: JSONValue) throws -> JSONValue {
		for expected in word.utf8 {
			guard try take() == expected else { throw failure }
		}
		return value
	}

	private mutating func digits() throws -> String {
		let start = position
		while let byte = next, Self.isDigit(byte) {
			position += 1
		}
		guard position > start else { throw failure }
		return String(decoding: bytes[start..<position], as: UTF8.self)
	}

	private mutating func number() throws -> Double {
		var text = ""
		if next == UInt8(ascii: "-") {
			position += 1
			text += "-"
		}
		let whole = try digits()
		guard whole.utf8.count == 1 || whole.utf8.first != UInt8(ascii: "0") else { throw failure }
		text += whole
		if next == UInt8(ascii: ".") {
			position += 1
			text += "." + (try digits())
		}
		if next == UInt8(ascii: "e") || next == UInt8(ascii: "E") {
			position += 1
			text += "e"
			if next == UInt8(ascii: "+") || next == UInt8(ascii: "-") {
				text += next == UInt8(ascii: "-") ? "-" : "+"
				position += 1
			}
			text += try digits()
		}
		guard let number = Double(text) else { throw failure }
		return number
	}

	private mutating func elements() throws -> [JSONValue] {
		position += 1
		var elements: [JSONValue] = []
		skipWhitespace()
		if next == UInt8(ascii: "]") {
			position += 1
			return elements
		}
		while true {
			elements.append(try value())
			skipWhitespace()
			switch try take() {
			case UInt8(ascii: ","):
				continue
			case UInt8(ascii: "]"):
				return elements
			default:
				throw failure
			}
		}
	}

	private mutating func members() throws -> [JSONMember] {
		position += 1
		var members: [JSONMember] = []
		var positions: [[UInt8]: Int] = [:]
		skipWhitespace()
		if next == UInt8(ascii: "}") {
			position += 1
			return members
		}
		while true {
			skipWhitespace()
			guard next == Self.quote else { throw failure }
			let key = try string()
			skipWhitespace()
			guard try take() == UInt8(ascii: ":") else { throw failure }
			let child = try value()
			let units = Array(key.utf8)
			if let sameKey = positions[units] {
				members[sameKey].value = child
			} else {
				positions[units] = members.count
				members.append(JSONMember(key: key, value: child))
			}
			skipWhitespace()
			switch try take() {
			case UInt8(ascii: ","):
				continue
			case UInt8(ascii: "}"):
				return Self.inEnumerationOrder(members)
			default:
				throw failure
			}
		}
	}

	private static func inEnumerationOrder(_ members: [JSONMember]) -> [JSONMember] {
		let indexed = members.filter { isArrayIndex($0.key) }
		guard !indexed.isEmpty else { return members }
		let ordered = indexed.sorted { (UInt64($0.key) ?? 0) < (UInt64($1.key) ?? 0) }
		return ordered + members.filter { !isArrayIndex($0.key) }
	}

	private mutating func string() throws -> String {
		position += 1
		var text: [UInt8] = []
		while true {
			let start = position
			while position < bytes.count, bytes[position] != Self.quote,
				bytes[position] != Self.backslash, bytes[position] >= 0x20
			{
				position += 1
			}
			text += bytes[start..<position]
			switch try take() {
			case Self.quote:
				return String(decoding: text, as: UTF8.self)
			case Self.backslash:
				text += Array(String(try escape()).utf8)
			default:
				throw failure
			}
		}
	}

	private mutating func escape() throws -> Unicode.Scalar {
		let byte = try take()
		switch byte {
		case Self.quote, Self.backslash, UInt8(ascii: "/"):
			return Unicode.Scalar(byte)
		case UInt8(ascii: "b"):
			return "\u{08}"
		case UInt8(ascii: "f"):
			return "\u{0C}"
		case UInt8(ascii: "n"):
			return "\n"
		case UInt8(ascii: "r"):
			return "\r"
		case UInt8(ascii: "t"):
			return "\t"
		case UInt8(ascii: "u"):
			return try escapedScalar()
		default:
			throw failure
		}
	}

	private mutating func escapedScalar() throws -> Unicode.Scalar {
		var code = try hexUnit()
		if (0xD800..<0xDC00).contains(code) {
			guard try take() == Self.backslash, try take() == UInt8(ascii: "u") else {
				throw failure
			}
			let low = try hexUnit()
			guard (0xDC00..<0xE000).contains(low) else { throw failure }
			code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
		}
		guard let scalar = Unicode.Scalar(code) else { throw failure }
		return scalar
	}

	private mutating func hexUnit() throws -> UInt32 {
		var unit: UInt32 = 0
		for _ in 0..<4 {
			guard let digit = Character(Unicode.Scalar(try take())).hexDigitValue else {
				throw failure
			}
			unit = (unit << 4) + UInt32(digit)
		}
		return unit
	}
}
