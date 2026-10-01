import EnduragentCoach
import SwiftUI

struct SidebarView: View {
	@Bindable var model: ShellModel

	var body: some View {
		List {
			NavigationLink(model.phrasebook.say(Catalog.creditsTitle, [:])) {
				CreditsView(model: model)
			}
			.accessibilityIdentifier("sidebar.credits")
			NavigationLink(model.phrasebook.say(Catalog.archiveHistory, [:])) {
				HistoryView(model: model)
			}
			.accessibilityIdentifier("sidebar.history")
			#if DEBUG
				NavigationLink(DebugMenuView.title) {
					DebugMenuView(model: model)
				}
				.accessibilityIdentifier("sidebar.debug")
			#endif
		}
		.navigationTitle(model.phrasebook.say(Catalog.chatMenu, [:]))
	}
}
