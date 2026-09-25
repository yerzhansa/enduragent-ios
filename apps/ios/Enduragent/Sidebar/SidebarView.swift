import EnduragentCoach
import SwiftUI

struct SidebarView: View {
	@Bindable var model: ShellModel

	var body: some View {
		List {
			NavigationLink("Credits") {
				CreditsView(model: model)
			}
			.accessibilityIdentifier("sidebar.credits")
			NavigationLink("History") {
				HistoryView(model: model)
			}
			.accessibilityIdentifier("sidebar.history")
			#if DEBUG
				NavigationLink("Debug") {
					DebugMenuView(model: model)
				}
				.accessibilityIdentifier("sidebar.debug")
			#endif
		}
		.navigationTitle(model.builder.phrasebook.say(Catalog.sidebarMenu, [:]))
	}
}
