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
				if let review = model.chat?.review {
					ConfirmedPreviewCard(model: model, review: review)
						.padding(.horizontal)
						.padding(.bottom, 8)
				}
				if let notice = model.reviewNotice {
					Text(notice.sentence(in: model.builder.phrasebook))
						.accessibilityIdentifier("chat.review.notice")
						.padding(.horizontal)
						.padding(.vertical, 8)
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
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Menu") {
						model.showSidebar = true
					}
					.accessibilityIdentifier("chat.sidebar")
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button("New chat") {
						model.newChat()
					}
				}
			}
			.navigationDestination(isPresented: $model.showCredits) {
				CreditsView(model: model)
			}
			.sheet(isPresented: $model.showSidebar) {
				NavigationStack {
					SidebarView(model: model)
				}
			}
		}
	}
}
