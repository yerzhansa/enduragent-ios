import EnduragentCoach
import SwiftUI

struct ReplyTableView: View {
	let table: ReplyTable

	var body: some View {
		ScrollView(.horizontal) {
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
				row(table.header, header: true)
				ForEach(table.rows.indices, id: \.self) { index in
					row(table.rows[index], header: false)
				}
			}
			.fixedSize(horizontal: true, vertical: true)
		}
		.fixedSize(horizontal: false, vertical: true)
		.scrollIndicators(.hidden)
		.accessibilityIdentifier("reply.table")
	}

	private func row(_ cells: [[ReplyRun]], header: Bool) -> some View {
		GridRow(alignment: .firstTextBaseline) {
			ForEach(cells.indices, id: \.self) { index in
				ReplyInlineView(runs: cells[index], font: header ? .caption.bold() : .subheadline)
					.foregroundStyle(header ? .secondary : .primary)
					.padding(.vertical, 7)
					.gridColumnAlignment(alignment(table.columns.elements[index]))
					.accessibilityIdentifier("reply.table.cell")
			}
		}
		.overlay(alignment: .bottom) {
			Rectangle().fill(.separator).frame(height: 0.5)
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
