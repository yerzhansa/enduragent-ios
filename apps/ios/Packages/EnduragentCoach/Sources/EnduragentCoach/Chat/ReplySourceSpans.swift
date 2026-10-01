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
		String(source[try linkRange(position)])
	}

	private func linkRange(_ position: AttributedString.MarkdownSourcePosition?) throws
		-> Range<String.Index>
	{
		let label = try range(position)
		guard label.lowerBound > source.startIndex else { throw ReplyParseFailure.sourceMapping }
		let opening = source.index(before: label.lowerBound)
		if source[opening] == "<" {
			guard label.upperBound < source.endIndex, source[label.upperBound] == ">" else {
				throw ReplyParseFailure.sourceMapping
			}
			return opening..<source.index(after: label.upperBound)
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
		return opening..<end
	}

	func block(_ indices: Range<Int>) throws -> String {
		let anchors = positions[indices].compactMap { $0 }
		guard let first = anchors.map(\.startLine).min(),
			var last = anchors.map(\.endLine).max(), first > 0, last <= lines.count
		else { throw ReplyParseFailure.sourceMapping }
		let next =
			positions[indices.upperBound...].compactMap { $0 }.first?.startLine
			?? (lines.count + 1)
		while last < next - 1, lines[last].drop(while: { $0.isWhitespace }).hasPrefix(">") {
			last += 1
		}
		return lines[(first - 1)..<last].joined(separator: "\n")
	}

	func omittedLinks(
		after previous: String.Index?, before next: String.Index?,
		inTableCell: Bool = false
	) throws -> [ReplyRun] {
		let start: String.Index
		if let previous {
			start = previous
		} else if let next {
			let separator: Character = inTableCell ? "|" : "\n"
			start =
				source[..<next].lastIndex(of: separator).map { source.index(after: $0) }
				?? source.startIndex
		} else {
			start = source.startIndex
		}
		let end: String.Index
		if let next {
			end = next
		} else if previous != nil {
			let separator: Character = inTableCell ? "|" : "\n"
			end = source[start...].firstIndex(of: separator) ?? source.endIndex
		} else {
			end = source.endIndex
		}
		guard start <= end else { return [] }
		var cursor = start
		var result: [ReplyRun] = []
		while let label = source.range(of: "[]", range: cursor..<end) {
			cursor = label.upperBound
			guard cursor < end, source[cursor] == "(" || source[cursor] == "[" else { continue }
			let prefix = String(source[..<label.lowerBound]) + "["
			let probe = prefix + "link]" + String(source[label.upperBound...])
			let labelStart = probe.index(probe.startIndex, offsetBy: prefix.count)
			let labelRange = labelStart..<probe.index(labelStart, offsetBy: 4)
			let parsed = try AttributedString(
				markdown: probe,
				options: .init(
					interpretedSyntax: .full, failurePolicy: .throwError,
					appliesSourcePositionAttributes: true))
			let url = parsed.runs.first { run in
				run.markdownSourcePosition.flatMap { Range<String.Index>($0, in: probe) }
					== labelRange
			}?.link
			guard let url, HTTPLink(validating: url) == nil else { continue }
			let closing: Character = source[cursor] == "(" ? ")" : "]"
			let tokenEnd = try balancedEnd(start: cursor, opening: source[cursor], closing: closing)
			guard tokenEnd <= end else { continue }
			result.append(.literal(String(source[label.lowerBound..<tokenEnd])))
			cursor = tokenEnd
		}
		return result
	}

	func validateOmittedLinks(in text: String) throws {
		let omitted = try omittedLinks(after: nil, before: nil)
		for literal in Set(omitted.map(\.accessibilityText)) {
			guard
				text.components(separatedBy: literal).count
					>= source.components(separatedBy: literal).count
			else { throw ReplyParseFailure.sourceMapping }
		}
	}

	func coverage(_ position: AttributedString.MarkdownSourcePosition?, isLink: Bool) throws
		-> Range<String.Index>
	{
		try isLink ? linkRange(position) : range(position)
	}

	func lineBreak(after cursor: String.Index) throws -> Range<String.Index> {
		guard let newline = source[cursor...].firstIndex(of: "\n") else {
			throw ReplyParseFailure.sourceMapping
		}
		return newline..<source.index(after: newline)
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
		var angleDestination = false
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
			if angleDestination {
				if character == ">" { angleDestination = false }
				continue
			}
			if opening == "(", depth == 1, character == "<" {
				angleDestination = true
			} else if opening == "(", followsWhitespace, character == "\"" || character == "'" {
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
