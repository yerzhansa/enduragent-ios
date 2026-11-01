import Foundation

struct OutputNumberScanner {
	let bytes: [UInt8]
	private(set) var cases: [[String]] = []
	private var index = 0

	init(bytes: [UInt8]) {
		self.bytes = bytes
	}

	mutating func document() throws {
		try object { key, scanner in
			if key == "cases" {
				try scanner.array { scanner in
					scanner.cases.append([])
					try scanner.object { key, scanner in
						try scanner.value(collecting: key == "output")
					}
				}
			} else {
				try scanner.value(collecting: false)
			}
		}
		skipWhitespace()
		guard index == bytes.count else { throw failure("text after the document") }
	}

	private mutating func value(collecting: Bool) throws {
		switch try peek() {
		case UInt8(ascii: "{"):
			try object { _, scanner in try scanner.value(collecting: collecting) }
		case UInt8(ascii: "["):
			try array { scanner in try scanner.value(collecting: collecting) }
		case UInt8(ascii: "\""):
			_ = try string()
		case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
			try literal()
		default:
			let token = try number()
			if collecting { cases[cases.count - 1].append(token) }
		}
	}

	private mutating func object(_ member: (String, inout Self) throws -> Void) throws {
		try expect("{")
		if try peek() == UInt8(ascii: "}") {
			index += 1
			return
		}
		repeat {
			let key = try string()
			try expect(":")
			try member(key, &self)
		} while try separated(closing: "}")
	}

	private mutating func array(_ element: (inout Self) throws -> Void) throws {
		try expect("[")
		if try peek() == UInt8(ascii: "]") {
			index += 1
			return
		}
		repeat {
			try element(&self)
		} while try separated(closing: "]")
	}

	private mutating func separated(closing: Unicode.Scalar) throws -> Bool {
		let next = try peek()
		index += 1
		if next == UInt8(ascii: ",") { return true }
		guard next == UInt8(ascii: closing) else { throw failure("a missing \(closing)") }
		return false
	}

	private mutating func string() throws -> String {
		try expect("\"")
		let start = index
		while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
			index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
		}
		guard index < bytes.count else { throw failure("an unterminated string") }
		index += 1
		return String(decoding: bytes[start..<index - 1], as: UTF8.self)
	}

	private mutating func number() throws -> String {
		let start = index
		while index < bytes.count, Self.numberBytes.contains(bytes[index]) {
			index += 1
		}
		guard index > start else { throw failure("an unexpected byte") }
		return String(decoding: bytes[start..<index], as: UTF8.self)
	}

	private mutating func literal() throws {
		while index < bytes.count, (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[index]) {
			index += 1
		}
	}

	private mutating func expect(_ scalar: Unicode.Scalar) throws {
		guard try peek() == UInt8(ascii: scalar) else { throw failure("a missing \(scalar)") }
		index += 1
	}

	private mutating func peek() throws -> UInt8 {
		skipWhitespace()
		guard index < bytes.count else { throw failure("the end of the text") }
		return bytes[index]
	}

	private mutating func skipWhitespace() {
		while index < bytes.count, Self.whitespace.contains(bytes[index]) {
			index += 1
		}
	}

	private func failure(_ found: String) -> PlanFixtureFailure {
		PlanFixtureFailure(description: "the fixture holds \(found) at byte \(index)")
	}

	private static let numberBytes = Set("-+.eE0123456789".utf8)
	private static let whitespace = Set(" \n\r\t".utf8)
}
