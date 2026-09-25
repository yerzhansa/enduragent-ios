import EnduragentCoach
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
			.navigationTitle(model.builder.phrasebook.say(Catalog.chatTitle, [:]))
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button(model.builder.phrasebook.say(Catalog.chatMenu, [:])) {
						model.showSidebar = true
					}
					.accessibilityIdentifier("chat.sidebar")
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button(model.builder.phrasebook.say(Catalog.sidebarNewChat, [:])) {
						model.newChat()
					}
				}
			}
			.sheet(isPresented: $model.showSidebar) {
				NavigationStack {
					SidebarView(model: model)
				}
			}
		}
	}
}
