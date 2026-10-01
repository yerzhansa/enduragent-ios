import Foundation

struct ReplySourceSpans {
	let source: String
	let lines: [Substring]
	let positions: [AttributedString.MarkdownSourcePosition?]
	private var recoveredRules: Set<Int> = []

	init(source: String, positions: [AttributedString.MarkdownSourcePosition?]) {
		self.source = source
		self.lines = source.split(separator: "\n", omittingEmptySubsequences: false)
		self.positions = positions
	}

	func label(_ position: AttributedString.MarkdownSourcePosition?) throws -> String {
		String(source[try range(position)])
	}

	func link(_ position: AttributedString.MarkdownSourcePosition?) throws -> String {
		let label = try range(position)
		guard label.lowerBound > source.startIndex else { throw ReplyParseFailure.sourceMapping }
		let opening = source.index(before: label.lowerBound)
		if source[opening] == "<" {
			guard label.upperBound < source.endIndex, source[label.upperBound] == ">" else {
				throw ReplyParseFailure.sourceMapping
			}
			return String(source[opening...label.upperBound])
		}
		guard source[opening] == "[", label.upperBound < source.endIndex,
			source[label.upperBound] == "]"
		else { throw ReplyParseFailure.sourceMapping }
		let after = source.index(after: label.upperBound)
		let end: String.Index
		if after < source.endIndex, source[after] == "(" {
			end = try balancedEnd(start: after, opening: "(", closing: ")")
		} else if after < source.endIndex, source[after] == "[" {
			end = try balancedEnd(start: after, opening: "[", closing: "]")
		} else {
			end = after
		}
		return String(source[opening..<end])
	}

	func block(_ indices: Range<Int>) throws -> String {
		let anchors = positions[indices].compactMap { $0 }
		guard let first = anchors.map(\.startLine).min(),
			let last = anchors.map(\.endLine).max(), first > 0, last <= lines.count
		else { throw ReplyParseFailure.sourceMapping }
		return lines[(first - 1)..<last].joined(separator: "\n")
	}

	mutating func rule(at index: Int) throws -> String {
		let previous = positions[..<index].compactMap { $0 }.last?.endLine ?? 0
		let next = positions[(index + 1)...].compactMap { $0 }.first?.startLine ?? (lines.count + 1)
		guard previous < next, previous >= 0, next <= lines.count + 1 else {
			throw ReplyParseFailure.sourceMapping
		}
		for line in previous..<(next - 1) where !recoveredRules.contains(line) {
			let text = lines[line]
			let markers = text.filter { !$0.isWhitespace }
			guard let marker = markers.first, "*-_".contains(marker), markers.count >= 3,
				markers.allSatisfy({ $0 == marker })
			else { continue }
			recoveredRules.insert(line)
			return String(text)
		}
		throw ReplyParseFailure.sourceMapping
	}

	private func range(_ position: AttributedString.MarkdownSourcePosition?) throws
		-> Range<String.Index>
	{
		guard let position, let range = Range<String.Index>(position, in: source),
			range.lowerBound >= source.startIndex, range.upperBound <= source.endIndex
		else { throw ReplyParseFailure.sourceMapping }
		return range
	}

	private func balancedEnd(start: String.Index, opening: Character, closing: Character) throws
		-> String.Index
	{
		var index = start
		var depth = 0
		var quote: Character?
		while index < source.endIndex {
			let character = source[index]
			let followsWhitespace =
				index > start && source[source.index(before: index)].isWhitespace
			index = source.index(after: index)
			if character == "\\" {
				if index < source.endIndex { index = source.index(after: index) }
				continue
			}
			if let activeQuote = quote {
				if character == activeQuote { quote = nil }
				continue
			}
			if opening == "(", followsWhitespace, character == "\"" || character == "'" {
				quote = character
			} else if character == opening {
				depth += 1
			} else if character == closing {
				depth -= 1
				if depth == 0 { return index }
			}
		}
		throw ReplyParseFailure.sourceMapping
	}
}
