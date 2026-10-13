import EnduragentCoach
import SwiftUI

struct ReplyTableView: View {
	let table: ReplyTable

	var body: some View {
		switch table.layout {
		case .stacked: ReplyStackedTable(lines: ReplyTableLine.lines(of: table))
		case .grid: ReplyGridTable(table: table, lines: ReplyTableLine.lines(of: table))
		}
	}
}

private struct ReplyTableLine {
	let cells: [[ReplyRun]]
	let description: ReplyRowDescription
	let isHeader: Bool

	static func lines(of table: ReplyTable) -> [ReplyTableLine] {
		[ReplyTableLine(cells: table.header, description: table.headerDescription, isHeader: true)]
			+ zip(table.rows, table.rowDescriptions).map { cells, description in
				ReplyTableLine(cells: cells, description: description, isHeader: false)
			}
	}

	func cell(_ runs: [ReplyRun]) -> some View {
		text(runs).padding(.vertical, 7)
	}

	func text(_ runs: [ReplyRun]) -> some View {
		ReplyInlineView(runs: runs, font: isHeader ? .caption.bold() : .subheadline)
			.foregroundStyle(isHeader ? .secondary : .primary)
	}
}

private struct ReplyTableLineElement: ViewModifier {
	let line: ReplyTableLine
	@Environment(\.openURL) private var openURL

	func body(content: Content) -> some View {
		content
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(Text(verbatim: line.description.accessibilityText))
			.accessibilityAddTraits(line.isHeader ? .isHeader : [])
			.accessibilityActions {
				ForEach(line.description.links.indices, id: \.self) { index in
					Button {
						openURL(line.description.links[index].target.url)
					} label: {
						Text(verbatim: line.description.links[index].label)
					}
				}
			}
			.accessibilityHidden(line.description.parts.isEmpty)
			.accessibilityIdentifier(line.isHeader ? "reply.table.header" : "reply.table.row")
	}
}

private struct ReplyTableSeparator: View {
	var body: some View {
		Rectangle().fill(.separator).frame(height: 0.5)
	}
}

private struct ReplyStackedTable: View {
	let lines: [ReplyTableLine]
	@Environment(\.dynamicTypeSize) private var textSize

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(lines.indices, id: \.self) { index in
				row(lines[index])
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func row(_ line: ReplyTableLine) -> some View {
		Group {
			if textSize.isAccessibilitySize {
				valueUnderMetric(line)
			} else {
				valueBesideMetric(line)
			}
		}
		.overlay(alignment: .bottom) { ReplyTableSeparator() }
		.modifier(ReplyTableLineElement(line: line))
	}

	private func valueUnderMetric(_ line: ReplyTableLine) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(line.cells.indices, id: \.self) { column in
				line.text(line.cells[column])
			}
		}
		.padding(.vertical, 7)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func valueBesideMetric(_ line: ReplyTableLine) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			ForEach(line.cells.indices, id: \.self) { column in
				if column == line.cells.startIndex {
					line.cell(line.cells[column])
						.frame(maxWidth: .infinity, alignment: .leading)
				} else {
					line.cell(line.cells[column])
						.multilineTextAlignment(.trailing)
				}
			}
		}
	}
}

private struct ReplyGridTable: View {
	let table: ReplyTable
	let lines: [ReplyTableLine]

	var body: some View {
		ScrollView(.horizontal) {
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
				ForEach(lines.indices, id: \.self) { index in
					row(lines[index], at: index)
				}
			}
			.overlayPreferenceValue(ReplyTableLineBounds.self) { bounds in
				GeometryReader { proxy in
					ForEach(lines.indices, id: \.self) { index in
						element(lines[index], cells: bounds[index] ?? [], in: proxy)
					}
				}
			}
			.fixedSize(horizontal: true, vertical: true)
		}
		.fixedSize(horizontal: false, vertical: true)
		.scrollIndicators(.hidden)
		.accessibilityIdentifier("reply.table")
	}

	private func row(_ line: ReplyTableLine, at index: Int) -> some View {
		GridRow(alignment: .firstTextBaseline) {
			ForEach(line.cells.indices, id: \.self) { column in
				line.cell(line.cells[column])
					.anchorPreference(key: ReplyTableLineBounds.self, value: .bounds) {
						[index: [$0]]
					}
					.accessibilityHidden(true)
					.gridColumnAlignment(alignment(table.columns.elements[column]))
			}
		}
		.overlay(alignment: .bottom) { ReplyTableSeparator() }
	}

	@ViewBuilder
	private func element(
		_ line: ReplyTableLine, cells: [Anchor<CGRect>], in proxy: GeometryProxy
	) -> some View {
		let frame = cells.reduce(CGRect.null) { $0.union(proxy[$1]) }
		if !frame.isNull {
			Color.clear
				.frame(width: proxy.size.width, height: frame.height)
				.offset(y: frame.minY)
				.allowsHitTesting(false)
				.modifier(ReplyTableLineElement(line: line))
		}
	}

	private func alignment(_ column: ColumnAlignment) -> HorizontalAlignment {
		switch column {
		case .left: .leading
		case .center: .center
		case .right: .trailing
		}
	}
}

private struct ReplyTableLineBounds: PreferenceKey {
	static var defaultValue: [Int: [Anchor<CGRect>]] { [:] }

	static func reduce(
		value: inout [Int: [Anchor<CGRect>]], nextValue: () -> [Int: [Anchor<CGRect>]]
	) {
		value.merge(nextValue()) { $0 + $1 }
	}
}
