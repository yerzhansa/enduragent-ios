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
				options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
		}
	}

	public func document(_ source: String) -> ReplyDocument {
		do {
			let parsed = try decode(source)
			let builder = ReplyBlockBuilder(parsed: parsed)
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
	let path: [PresentationIntent.IntentType]
}

private struct ReplyNode {
	let kind: PresentationIntent.Kind?
	let indices: Range<Int>
	let children: [ReplyNode]
}

private struct ReplyBlockBuilder {
	let tokens: [ReplyToken]

	init(parsed: AttributedString) {
		tokens = parsed.runs.map { run in
			ReplyToken(
				text: String(parsed[run.range].characters),
				inline: run.inlinePresentationIntent ?? [], link: run.link,
				path: Array((run.presentationIntent?.components ?? []).reversed()))
		}
	}

	func document() throws -> [ReplyBlock] {
		try blocks(nodes(in: tokens.indices, depth: 0))
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

	private func blocks(_ nodes: [ReplyNode]) throws -> [ReplyBlock] {
		try nodes.map(block)
	}

	private func block(_ node: ReplyNode) throws -> ReplyBlock {
		switch node.kind {
		case .paragraph: return .paragraph(runs(node.indices))
		case .header(let level):
			guard let heading = HeadingLevel(rawValue: level) else {
				throw ReplyParseFailure.documentStructure
			}
			return .heading(heading, runs(node.indices))
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
		case .thematicBreak, .blockQuote, nil:
			return .paragraph([.literal(literalText(node))])
		case .listItem, .tableHeaderRow, .tableRow, .tableCell:
			throw ReplyParseFailure.documentStructure
		@unknown default:
			return .paragraph([.literal(literalText(node))])
		}
	}

	private func literalText(_ node: ReplyNode) -> String {
		switch node.kind {
		case .thematicBreak: return "---"
		case .blockQuote:
			return node.children.map { child in
				"> " + literalText(child).replacingOccurrences(of: "\n", with: "\n> ")
			}.joined(separator: "\n\n")
		default:
			return node.children.isEmpty
				? runs(node.indices).map(\.accessibilityText).joined()
				: node.children.map(literalText).joined(separator: "\n\n")
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
				cells[index] = runs(cell.indices)
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

	private func runs(_ indices: Range<Int>) -> [ReplyRun] {
		var result: [ReplyRun] = []
		for token in tokens[indices] {
			let run: ReplyRun
			if let url = token.link {
				if let target = HTTPLink(validating: url) {
					run = .link(label: [styled(token.text, intent: token.inline)], target: target)
				} else {
					run = .literal("[\(token.text)](\(url.absoluteString))")
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
		return result
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
