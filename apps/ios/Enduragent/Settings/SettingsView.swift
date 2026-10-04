import EnduragentCoach
import SwiftUI

struct SettingsView: View {
	var model: ShellModel

	var body: some View {
		List {
			Section(model.phrasebook.say(Catalog.settingsModelAccessTitle, [:])) {
				NavigationLink(
					model.phrasebook.say(Catalog.accessTitle), value: ShellDestination.accessMethod
				)
				.accessibilityIdentifier("settings.accessMethod")
				if let choices = model.modelChoices {
					NavigationLink(value: ShellDestination.modelPicker) {
						LabeledContent(
							model.phrasebook.say(Catalog.settingsCoachModel),
							value: choices.selected.details.displayName)
					}
					.accessibilityIdentifier("settings.model")
				}
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
			Section(model.phrasebook.say(Catalog.settingsLanguageTitle)) {
				Button {
					model.openLanguagePicker()
				} label: {
					LabeledContent(
						model.phrasebook.say(Catalog.settingsLanguageTitle),
						value: model.languagePreference.title(in: model.phrasebook))
				}
				.foregroundStyle(Color.primary)
				.accessibilityIdentifier("settings.language")
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
