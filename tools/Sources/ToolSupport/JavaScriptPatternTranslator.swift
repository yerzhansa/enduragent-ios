public struct PatternFailure: DescribedFailure {
	public let description: String
}

struct JavaScriptPatternTranslator {
	private static let word = "A-Za-z0-9_"
	private static let space =
		#"\t\n\u000B\f\r \u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"#
	private static let boundary =
		"(?:(?<=[\(word)])(?![\(word)])|(?<![\(word)])(?=[\(word)]))"
	private static let anyButLineEnd = #"[^\n\r\u2028\u2029]"#

	private let source: [Unicode.Scalar]
	private let ignoringCase: Bool
	private var position = 0
	private var output: [String] = []
	private var openGroups: [OpenGroup] = []
	private var captureCount = 0
	private var optionalCaptures: Set<Int> = []
	private var preceding = Preceding.atom

	private struct OpenGroup {
		let start: Int
		let capture: Int?
		let capturesWhenOpened: Int
	}

	private enum Preceding {
		case atom
		case groupHoldingCapture
		case quantifier
		case lazyQuantifier
	}

	static func translate(_ source: String, ignoringCase: Bool) throws -> String {
		var translator = JavaScriptPatternTranslator(
			source: Array(source.unicodeScalars), ignoringCase: ignoringCase)
		return try translator.translate()
	}

	private var next: Unicode.Scalar? {
		position < source.count ? source[position] : nil
	}

	private var failure: PatternFailure {
		PatternFailure(
			description:
				"Unsupported pattern at \(position): \(String(String.UnicodeScalarView(source)))")
	}

	private mutating func take() throws -> Unicode.Scalar {
		guard let scalar = next else { throw failure }
		position += 1
		return scalar
	}

	private mutating func translate() throws -> String {
		guard source.allSatisfy({ (0x20..<0x7F).contains($0.value) }) else { throw failure }
		while let scalar = next {
			let quantifierEnd = quantifierEnd(at: position)
			position += 1
			if let quantifierEnd {
				try repeatPreceding(lazily: scalar == "?")
				output.append(
					String(String.UnicodeScalarView(source[(position - 1)..<quantifierEnd])))
				position = quantifierEnd
				continue
			}
			preceding = .atom
			switch scalar {
			case "\\":
				output.append(try escape())
			case "[":
				output.append(try characterClass())
			case "(":
				try openGroup()
			case ")":
				try closeGroup()
			case ".":
				output.append(Self.anyButLineEnd)
			case "$":
				output.append(#"\z"#)
			case "]":
				throw failure
			default:
				output.append(literal(scalar))
			}
		}
		guard openGroups.isEmpty else { throw failure }
		return output.joined()
	}

	private func quantifierEnd(at start: Int) -> Int? {
		guard ["*", "+", "?"].contains(source[start]) else {
			return source[start] == "{" ? countedQuantifierEnd(at: start) : nil
		}
		return start + 1
	}

	private func countedQuantifierEnd(at start: Int) -> Int? {
		var index = start + 1
		let digits: (inout Int) -> Bool = { index in
			let first = index
			while index < source.count, ("0"..."9").contains(source[index]) {
				index += 1
			}
			return index > first
		}
		guard digits(&index) else { return nil }
		if index < source.count, source[index] == "," {
			index += 1
			_ = digits(&index)
		}
		guard index < source.count, source[index] == "}" else { return nil }
		return index + 1
	}

	private mutating func repeatPreceding(lazily: Bool) throws {
		switch (preceding, lazily) {
		case (.atom, _):
			preceding = .quantifier
		case (.quantifier, true):
			preceding = .lazyQuantifier
		default:
			throw failure
		}
	}

	private func isLetter(_ scalar: Unicode.Scalar) -> Bool {
		("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
	}

	private func isWord(_ scalar: Unicode.Scalar) -> Bool {
		isLetter(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
	}

	private func literal(_ scalar: Unicode.Scalar) -> String {
		guard ignoringCase, isLetter(scalar) else { return String(scalar) }
		return "[\(bothCases(scalar))]"
	}

	private func bothCases(_ scalar: Unicode.Scalar) -> String {
		let letter = String(scalar)
		return letter.lowercased() + letter.uppercased()
	}

	private mutating func escape() throws -> String {
		let scalar = try take()
		switch scalar {
		case "b":
			return Self.boundary
		case "w":
			return "[\(Self.word)]"
		case "W":
			return "[^\(Self.word)]"
		case "d":
			return "[0-9]"
		case "D":
			return "[^0-9]"
		case "s":
			return "[\(Self.space)]"
		case "S":
			return "[^\(Self.space)]"
		case "n", "r", "t":
			return "\\\(scalar)"
		case "/":
			return "/"
		case "1"..."9":
			return try backreference(scalar)
		default:
			guard !isWord(scalar), scalar != " " else { throw failure }
			return "\\\(scalar)"
		}
	}

	private func backreference(_ scalar: Unicode.Scalar) throws -> String {
		guard let number = Int(String(scalar)), optionalCaptures.contains(number) else {
			throw failure
		}
		if let following = next, ("0"..."9").contains(following) { throw failure }
		return "\\\(number)"
	}

	private mutating func characterClass() throws -> String {
		var set = "["
		if next == "^" {
			position += 1
			set += "^"
		}
		var previousIsWord = false
		var members = 0
		while true {
			let scalar = try take()
			if scalar == "]" { break }
			members += 1
			let isRangeStart = next == "-"
			switch scalar {
			case "\\":
				set += try classEscape()
				previousIsWord = false
			case "-":
				guard !ignoringCase, previousIsWord, let end = next, isWord(end) else {
					throw failure
				}
				set += "-"
				previousIsWord = false
			case _ where isWord(scalar):
				if ignoringCase, isLetter(scalar) {
					guard !isRangeStart else { throw failure }
					set += bothCases(scalar)
				} else {
					set += String(scalar)
				}
				previousIsWord = true
			case " ":
				set += " "
				previousIsWord = false
			default:
				set += "\\\(scalar)"
				previousIsWord = false
			}
		}
		guard members > 0 else { throw failure }
		return set + "]"
	}

	private mutating func classEscape() throws -> String {
		let scalar = try take()
		switch scalar {
		case "w":
			return Self.word
		case "W":
			return "[^\(Self.word)]"
		case "d":
			return "0-9"
		case "D":
			return "[^0-9]"
		case "s":
			return Self.space
		case "S":
			return "[^\(Self.space)]"
		case "n", "r", "t":
			return "\\\(scalar)"
		case "/":
			return "/"
		default:
			guard !isWord(scalar), scalar != " " else { throw failure }
			return "\\\(scalar)"
		}
	}

	private mutating func openGroup() throws {
		guard next == "?" else {
			captureCount += 1
			openGroups.append(
				OpenGroup(
					start: output.count, capture: captureCount, capturesWhenOpened: captureCount))
			output.append("(")
			return
		}
		position += 1
		let kind = try take()
		guard [":", "=", "!"].contains(kind) else { throw failure }
		openGroups.append(
			OpenGroup(start: output.count, capture: nil, capturesWhenOpened: captureCount))
		output.append("(?\(kind)")
	}

	private mutating func closeGroup() throws {
		guard let group = openGroups.popLast() else { throw failure }
		let holdsCapture = captureCount > group.capturesWhenOpened
		guard let capture = group.capture, next == "?" else {
			output.append(")")
			preceding = holdsCapture ? .groupHoldingCapture : .atom
			return
		}
		position += 1
		guard !holdsCapture, next != "?" else { throw failure }
		preceding = .quantifier
		let inner = output[(group.start + 1)...].joined()
		output.removeSubrange(group.start...)
		output.append("((?:\(inner))?)")
		optionalCaptures.insert(capture)
	}
}
