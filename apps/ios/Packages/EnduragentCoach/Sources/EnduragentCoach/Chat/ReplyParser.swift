import Foundation

public struct ReplyParser: Sendable {
	private let decode: @Sendable (String) throws -> AttributedString

	init(decode: @escaping @Sendable (String) throws -> AttributedString) {
		self.decode = decode
	}

	public static var foundation: Self {
		Self { source in
			try AttributedString(
				markdown: source,
				options: .init(
					interpretedSyntax: .full, failurePolicy: .throwError,
					appliesSourcePositionAttributes: true))
		}
	}

	public func document(_ source: String) -> ReplyDocument {
		do {
			let parsed = try decode(source)
			var builder = ReplyBlockBuilder(parsed: parsed, source: source)
			return .blocks(try builder.document())
		} catch let failure as ReplyParseFailure {
			return .plainText(source: source, failure: failure)
		} catch {
			let failure = error as NSError
			return .plainText(
				source: source, failure: .foundation(domain: failure.domain, code: failure.code))
		}
	}

	#if DEBUG
		public static var failingForProof: Self {
			Self { _ in throw ReplyParseFailure.injected }
		}
	#endif
}

private struct ReplyToken {
	let text: String
	let inline: InlinePresentationIntent
	let link: URL?
	let position: AttributedString.MarkdownSourcePosition?
	let path: [PresentationIntent.IntentType]
}

private struct ReplyNode {
	let kind: PresentationIntent.Kind?
	let indices: Range<Int>
	let children: [ReplyNode]
}

private struct ReplyBlockBuilder {
	let tokens: [ReplyToken]
	var spans: ReplySourceSpans

	init(parsed: AttributedString, source: String) {
		tokens = parsed.runs.map { run in
			ReplyToken(
				text: String(parsed[run.range].characters),
				inline: run.inlinePresentationIntent ?? [], link: run.link,
				position: run.markdownSourcePosition,
				path: Array((run.presentationIntent?.components ?? []).reversed()))
		}
		spans = ReplySourceSpans(source: source, positions: tokens.map(\.position))
	}

	mutating func document() throws -> [ReplyBlock] {
		if tokens.isEmpty {
			let omitted = try spans.omittedLinks(after: nil, before: nil)
			guard omitted.isEmpty || omitted.map(\.accessibilityText).joined() == spans.source
			else {
				throw ReplyParseFailure.sourceMapping
			}
			return omitted.isEmpty ? [] : [.paragraph(omitted)]
		}
		let result = try blocks(nodes(in: tokens.indices, depth: 0))
		try spans.validateOmittedLinks(in: ReplyDocument.blocks(result).accessibilityText)
		return result
	}

	private func nodes(in indices: Range<Int>, depth: Int) -> [ReplyNode] {
		var result: [ReplyNode] = []
		var start = indices.lowerBound
		while start < indices.upperBound {
			guard tokens[start].path.count > depth else {
				result.append(ReplyNode(kind: nil, indices: start..<(start + 1), children: []))
				start += 1
				continue
			}
			let intent = tokens[start].path[depth]
			var end = start + 1
			while end < indices.upperBound, tokens[end].path.count > depth,
				tokens[end].path[depth].identity == intent.identity
			{
				end += 1
			}
			let children =
				tokens[start].path.count > depth + 1
				? nodes(in: start..<end, depth: depth + 1) : []
			result.append(ReplyNode(kind: intent.kind, indices: start..<end, children: children))
			start = end
		}
		return result
	}

	private mutating func blocks(_ nodes: [ReplyNode]) throws -> [ReplyBlock] {
		var result: [ReplyBlock] = []
		for node in nodes { result.append(try block(node)) }
		return result
	}

	private mutating func block(_ node: ReplyNode) throws -> ReplyBlock {
		switch node.kind {
		case .paragraph: return .paragraph(try runs(node.indices))
		case .header(let level):
			guard let heading = HeadingLevel(rawValue: level) else {
				throw ReplyParseFailure.documentStructure
			}
			return .heading(heading, try runs(node.indices))
		case .codeBlock(let language):
			return .codeBlock(text: tokens[node.indices].map(\.text).joined(), language: language)
		case .orderedList:
			var items: [NumberedItem] = []
			for item in node.children {
				guard case .listItem(let number) = item.kind, let ordinal = UInt(exactly: number)
				else {
					throw ReplyParseFailure.documentStructure
				}
				items.append(
					NumberedItem(
						ordinal: ordinal, blocks: try NonEmpty(validating: blocks(item.children))))
			}
			return .list(.ordered(try NonEmpty(validating: items)))
		case .unorderedList:
			var items: [NonEmpty<ReplyBlock>] = []
			for item in node.children {
				guard case .listItem = item.kind else { throw ReplyParseFailure.documentStructure }
				items.append(try NonEmpty(validating: blocks(item.children)))
			}
			return .list(.unordered(try NonEmpty(validating: items)))
		case .table(let columns): return .table(try table(node, columns: columns))
		case .thematicBreak:
			return .paragraph([.literal(try spans.rule(at: node.indices.lowerBound))])
		case .blockQuote: return .paragraph([.literal(try spans.block(node.indices))])
		case nil:
			return .paragraph([.literal(tokens[node.indices].map(\.text).joined())])
		case .listItem, .tableHeaderRow, .tableRow, .tableCell:
			throw ReplyParseFailure.documentStructure
		@unknown default:
			return .paragraph([.literal(try spans.block(node.indices))])
		}
	}

	private func table(_ node: ReplyNode, columns: [PresentationIntent.TableColumn]) throws
		-> ReplyTable
	{
		let alignments = try columns.map { column -> ColumnAlignment in
			switch column.alignment {
			case .left: return .left
			case .center: return .center
			case .right: return .right
			@unknown default: throw ReplyParseFailure.documentStructure
			}
		}
		var header: [[ReplyRun]] = Array(repeating: [], count: columns.count)
		var rows: [[[ReplyRun]]] = []
		for row in node.children {
			var cells: [[ReplyRun]] = Array(repeating: [], count: columns.count)
			for cell in row.children {
				guard case .tableCell(let index) = cell.kind, cells.indices.contains(index) else {
					throw ReplyParseFailure.documentStructure
				}
				cells[index] = try runs(cell.indices)
			}
			switch row.kind {
			case .tableHeaderRow: header = cells
			case .tableRow(let index):
				guard index > 0 else { throw ReplyParseFailure.documentStructure }
				while rows.count < index { rows.append(Array(repeating: [], count: columns.count)) }
				rows[index - 1] = cells
			default: throw ReplyParseFailure.documentStructure
			}
		}
		return try ReplyTable(
			validating: NonEmpty(validating: alignments), header: header, rows: rows)
	}

	private func runs(_ indices: Range<Int>) throws -> [ReplyRun] {
		var result: [ReplyRun] = []
		var cursor: String.Index?
		let inTableCell =
			tokens[indices].first?.path.contains { intent in
				if case .tableCell = intent.kind { return true }
				return false
			} ?? false
		for token in tokens[indices] {
			if token.position != nil {
				let coverage = try spans.coverage(token.position, isLink: token.link != nil)
				result += try spans.omittedLinks(
					after: cursor, before: coverage.lowerBound,
					inTableCell: inTableCell)
				cursor = coverage.upperBound
			} else if let start = cursor,
				token.inline.contains(.softBreak) || token.inline.contains(.lineBreak)
			{
				let lineBreak = try spans.lineBreak(after: start)
				result += try spans.omittedLinks(after: start, before: lineBreak.lowerBound)
				cursor = lineBreak.upperBound
			}
			let run: ReplyRun
			if let url = token.link {
				if let target = HTTPLink(validating: url) {
					run = .link(label: try styledLabel(token), target: target)
				} else {
					run = .literal(try spans.link(token.position))
				}
			} else if token.inline.contains(.inlineHTML) || token.inline.contains(.blockHTML) {
				run = .literal(token.text)
			} else {
				run = .text(styled(token.text, intent: token.inline))
			}
			if case .literal(let previous) = result.last, case .literal(let current) = run {
				result[result.count - 1] = .literal(previous + current)
			} else if case .text(let previous) = result.last, case .text(let current) = run,
				previous.styles == current.styles
			{
				result[result.count - 1] = .text(
					StyledText(
						text: previous.text + current.text, styles: current.styles))
			} else {
				result.append(run)
			}
		}
		result += try spans.omittedLinks(
			after: cursor, before: nil,
			inTableCell: inTableCell)
		return result
	}

	private func styledLabel(_ token: ReplyToken) throws -> [StyledText] {
		let source = try spans.label(token.position)
		let label = try AttributedString(
			markdown: source,
			options: .init(
				interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .throwError))
		return label.runs.map { run in
			let text = String(label[run.range].characters)
			return styled(text, intent: (run.inlinePresentationIntent ?? []).union(token.inline))
		}
	}

	private func styled(_ text: String, intent: InlinePresentationIntent) -> StyledText {
		let styles: [(InlinePresentationIntent, InlineStyle)] = [
			(.stronglyEmphasized, .bold), (.emphasized, .italic),
			(.strikethrough, .strikethrough), (.code, .inlineCode),
		]
		return StyledText(
			text: intent.contains(.softBreak) ? "\n" : text,
			styles: Set(styles.compactMap { intent.contains($0.0) ? $0.1 : nil }))
	}
}
