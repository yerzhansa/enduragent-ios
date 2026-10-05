struct CatalogFailure: Error, CustomStringConvertible {
	let description: String
}

struct CatalogMember {
	let key: String
	var value: CatalogNode
}

enum CatalogNode {
	case text(String)
	case group([CatalogMember])
}

struct CatalogReader {
	private let scalars: [Unicode.Scalar]
	private var position = 0

	static func read(_ text: String) throws -> CatalogNode {
		var reader = CatalogReader(scalars: Array(text.unicodeScalars))
		let node = try reader.value()
		reader.skipWhitespace()
		guard reader.position == reader.scalars.count else { throw reader.failure }
		return node
	}

	private var next: Unicode.Scalar? {
		position < scalars.count ? scalars[position] : nil
	}

	private var failure: CatalogFailure {
		CatalogFailure(description: "Invalid catalog JSON at character \(position)")
	}

	private mutating func skipWhitespace() {
		while let scalar = next, [" ", "\t", "\n", "\r"].contains(scalar) {
			position += 1
		}
	}

	private mutating func take() throws -> Unicode.Scalar {
		guard let scalar = next else { throw failure }
		position += 1
		return scalar
	}

	private mutating func value() throws -> CatalogNode {
		skipWhitespace()
		switch next {
		case "\"":
			return .text(try string())
		case "{":
			return .group(try members())
		default:
			throw failure
		}
	}

	private mutating func members() throws -> [CatalogMember] {
		position += 1
		var members: [CatalogMember] = []
		skipWhitespace()
		if next == "}" {
			position += 1
			return members
		}
		while true {
			skipWhitespace()
			guard next == "\"" else { throw failure }
			let key = try string()
			skipWhitespace()
			guard try take() == ":" else { throw failure }
			let child = try value()
			let sameKey = members.firstIndex {
				$0.key.unicodeScalars.elementsEqual(key.unicodeScalars)
			}
			if let sameKey {
				members[sameKey].value = child
			} else {
				members.append(CatalogMember(key: key, value: child))
			}
			skipWhitespace()
			switch try take() {
			case ",":
				continue
			case "}":
				return members
			default:
				throw failure
			}
		}
	}

	private mutating func string() throws -> String {
		position += 1
		var text = String.UnicodeScalarView()
		while true {
			let scalar = try take()
			switch scalar {
			case "\"":
				return String(text)
			case "\\":
				text.append(try escape())
			case _ where scalar.value < 0x20:
				throw failure
			default:
				text.append(scalar)
			}
		}
	}

	private mutating func escape() throws -> Unicode.Scalar {
		let scalar = try take()
		switch scalar {
		case "\"", "\\", "/":
			return scalar
		case "b":
			return "\u{08}"
		case "f":
			return "\u{0C}"
		case "n":
			return "\n"
		case "r":
			return "\r"
		case "t":
			return "\t"
		case "u":
			return try escapedScalar()
		default:
			throw failure
		}
	}

	private mutating func escapedScalar() throws -> Unicode.Scalar {
		var code = try hexUnit()
		if (0xD800..<0xDC00).contains(code) {
			guard try take() == "\\", try take() == "u" else { throw failure }
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
			let scalar = try take()
			guard scalar.isASCII, let digit = Character(scalar).hexDigitValue else { throw failure }
			unit = (unit << 4) + UInt32(digit)
		}
		return unit
	}
}
