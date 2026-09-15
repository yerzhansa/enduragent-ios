import SwiftUI

struct HistoryView: View {
	var model: ShellModel

	var body: some View {
		List(model.history) { row in
			Button {
				Task { await model.openChat(row.id) }
			} label: {
				VStack(alignment: .leading) {
					Text(row.title)
					Text(row.civilDate.rawValue)
				}
			}
			.accessibilityIdentifier("history.row.\(row.id.rawValue)")
		}
		.navigationTitle("History")
		.task {
			await model.reloadHistory()
		}
	}
}
