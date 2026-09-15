import SwiftUI

struct ChatView: View {
	@Bindable var model: ShellModel

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				TranscriptView(model: model)
				if model.slashListVisible {
					SlashListView(model: model)
				}
				if let pending = model.seam.pendingWrite {
					ConfirmedPreviewCard(model: model, pending: pending)
						.padding(.horizontal)
						.padding(.bottom, 8)
				}
				if let errorLine = model.errorLine {
					Text(errorLine)
						.accessibilityIdentifier("chat.error")
						.padding(.horizontal)
						.padding(.vertical, 8)
				}
				ComposerView(model: model)
			}
			.navigationTitle("Coach")
		}
	}
}
