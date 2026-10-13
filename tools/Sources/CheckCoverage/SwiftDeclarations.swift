struct SwiftDeclarations {
	private(set) var functions: Set<String> = []
	private(set) var methodsByType: [String: Set<String>] = [:]

	init(source: String) {
		var words = SwiftWords(bytes: Array(source.utf8))
		var open: [String?] = []
		var opening: String?
		var previous = ""
		while let word = words.next() {
			switch word {
			case "{":
				open.append(opening)
				opening = nil
			case "}":
				_ = open.popLast()
			default:
				if previous == "func" {
					functions.insert(word)
					for type in open.compactMap({ $0 }) {
						methodsByType[type, default: []].insert(word)
					}
				} else if previous == "class" || previous == "extension" {
					opening = Self.keywords.contains(word) ? nil : word
				}
			}
			previous = word
		}
	}

	func declares(function: String) -> Bool {
		functions.contains(function)
	}

	func declares(method: String, in type: String) -> Bool {
		methodsByType[type]?.contains(method) ?? false
	}

	private static let keywords: Set<String> = ["func", "var", "let", "subscript"]
}

private struct SwiftWords {
	private static let quote = UInt8(ascii: "\"")
	private static let hash = UInt8(ascii: "#")
	private static let backslash = UInt8(ascii: "\\")

	let bytes: [UInt8]
	private var position = 0

	init(bytes: [UInt8]) {
		self.bytes = bytes
	}

	mutating func next() -> String? {
		while position < bytes.count {
			let byte = bytes[position]
			if Self.isWord(byte) {
				let start = position
				while position < bytes.count, Self.isWord(bytes[position]) { position += 1 }
				return String(decoding: bytes[start..<position], as: UTF8.self)
			}
			if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") {
				position += 1
				return String(decoding: [byte], as: UTF8.self)
			}
			if !skipString() { position += 1 }
		}
		return nil
	}

	private static func isWord(_ byte: UInt8) -> Bool {
		byte == UInt8(ascii: "_") || byte >= 0x80
			|| (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
			|| (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
			|| (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
	}

	private func count(of byte: UInt8, at start: Int) -> Int {
		var end = start
		while end < bytes.count, bytes[end] == byte { end += 1 }
		return end - start
	}

	private mutating func skipString() -> Bool {
		let hashes = count(of: Self.hash, at: position)
		let quotes = count(of: Self.quote, at: position + hashes)
		guard quotes > 0 else { return false }
		let delimiter = quotes >= 3 ? 3 : 1
		position += hashes + delimiter
		while position < bytes.count {
			if bytes[position] == Self.backslash,
				count(of: Self.hash, at: position + 1) == hashes
			{
				position += 1 + hashes
				if position < bytes.count, bytes[position] == UInt8(ascii: "(") {
					skipInterpolation()
				} else {
					position += 1
				}
			} else if count(of: Self.quote, at: position) >= delimiter,
				count(of: Self.hash, at: position + delimiter) >= hashes
			{
				position += delimiter + hashes
				return true
			} else {
				position += 1
			}
		}
		return true
	}

	private mutating func skipInterpolation() {
		var depth = 0
		while position < bytes.count {
			let byte = bytes[position]
			if byte == UInt8(ascii: "(") {
				depth += 1
			} else if byte == UInt8(ascii: ")") {
				depth -= 1
				if depth == 0 {
					position += 1
					return
				}
			}
			if !skipString() { position += 1 }
		}
	}
}
