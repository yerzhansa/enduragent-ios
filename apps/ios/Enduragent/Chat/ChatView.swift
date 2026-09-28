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
				if let pending = model.visibleProposal {
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
			#if DEBUG
				.overlay(alignment: .topLeading) {
					if let snapshot = model.chat {
						TurnProgressDebugView(snapshot: snapshot)
					}
				}
			#endif
			.navigationTitle(model.phrasebook.say(Catalog.chatViewTitle, [:]))
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Menu") {
						model.showSidebar = true
					}
					.accessibilityIdentifier("chat.sidebar")
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button(model.phrasebook.say(Catalog.chatNewConversationConfirm, [:])) {
						Task { await model.newConversation() }
					}
					.accessibilityIdentifier("chat.newConversation")
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
			.sheet(isPresented: $model.showLanguage) {
				NavigationStack {
					LanguageView(model: model)
						.toolbar {
							ToolbarItem(placement: .topBarTrailing) {
								Button {
									model.showLanguage = false
								} label: {
									Image(systemName: "xmark")
								}
								.accessibilityLabel(
									model.phrasebook.say(Catalog.chatViewCloseContext, [:])
								)
								.accessibilityIdentifier("language.close")
							}
						}
				}
			}
		}
	}
}
