import EnduragentCoach
import SwiftUI

struct ChatView: View {
	@Bindable var model: ShellModel

	var body: some View {
		NavigationStack {
			TranscriptView(model: model)
				.safeAreaInset(edge: .bottom, spacing: 0) {
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
						Button(model.phrasebook.say(Catalog.chatMenu, [:])) {
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
					.presentationDetents([.fraction(LanguageSheetLayout.heightFraction)])
					.presentationDragIndicator(.visible)
				}
		}
	}
}
