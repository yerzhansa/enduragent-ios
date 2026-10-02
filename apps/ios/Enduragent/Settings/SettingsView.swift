import EnduragentCoach
import SwiftUI

struct SettingsView: View {
	var model: ShellModel

	var body: some View {
		List {
			Section(model.phrasebook.say(Catalog.settingsModelAccessTitle, [:])) {
				NavigationLink(
					model.phrasebook.say(Catalog.creditsTitle, [:]), value: ShellDestination.credits
				)
				.accessibilityIdentifier("settings.credits")
			}
			#if DEBUG
				Section {
					NavigationLink(SettingsDebugView.title, value: ShellDestination.debug)
						.accessibilityIdentifier("settings.debug")
				}
			#endif
		}
		.navigationTitle(model.phrasebook.say(Catalog.settingsTitle, [:]))
	}
}
