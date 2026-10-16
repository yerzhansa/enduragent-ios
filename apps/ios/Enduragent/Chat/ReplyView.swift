import EnduragentCoach
import SwiftUI

struct ReplyView: View {
	let source: String
	let parser: ReplyParser

	var body: some View {
		Group {
			switch parser.document(source) {
			case .blocks(let blocks):
				ReplyBlocksView(blocks: blocks)
			case .plainText(let source, _):
				Text(verbatim: source)
					.fixedSize(horizontal: false, vertical: true)
					.accessibilityIdentifier("reply.fallback")
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct ReplyBlocksView: View {
	let blocks: [ReplyBlock]

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			ForEach(blocks.indices, id: \.self) { index in
				ReplyBlockView(block: blocks[index])
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct ReplyBlockView: View {
	let block: ReplyBlock

	var body: some View {
		switch block {
		case .paragraph(let runs):
			ReplyInlineView(runs: runs)
				.accessibilityIdentifier("reply.paragraph")
		case .heading(_, let runs):
			ReplyInlineView(runs: runs, font: .body.bold())
				.accessibilityAddTraits(.isHeader)
				.accessibilityIdentifier("reply.heading")
		case .list(let list):
			VStack(alignment: .leading, spacing: 8) {
				switch list {
				case .ordered(let items):
					ForEach(items.elements.indices, id: \.self) { index in
						item(
							items.elements[index].blocks,
							marker: "\(items.elements[index].ordinal).")
					}
				case .unordered(let items):
					ForEach(items.elements.indices, id: \.self) { index in
						item(items.elements[index], marker: "•")
					}
				}
			}
		case .codeBlock(let text, _):
			Text(verbatim: text)
				.font(.system(.subheadline, design: .monospaced))
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(12)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
				.accessibilityIdentifier("reply.code")
		case .table(let table):
			ReplyTableView(table: table)
		}
	}

	private func item(_ blocks: NonEmpty<ReplyBlock>, marker: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Text(verbatim: marker)
				.frame(minWidth: 16, alignment: .trailing)
				.accessibilityHidden(true)
			ReplyBlocksView(blocks: blocks.elements)
		}
	}
}
