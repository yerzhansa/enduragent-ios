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
			Section(model.phrasebook.say(Catalog.settingsTrainingSection)) {
				NavigationLink(
					model.phrasebook.say(Catalog.settingsTrainingTitle),
					value: ShellDestination.training
				)
				.accessibilityIdentifier("settings.training")
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
