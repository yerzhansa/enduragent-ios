import EnduragentCoach
import SwiftUI

struct SupportSection: View {
	var model: ShellModel

	var body: some View {
		Section(model.phrasebook.say(Catalog.settingsSupportTitle)) {
			NavigationLink(
				model.phrasebook.say(Catalog.feedbackTitle), value: ShellDestination.feedback
			)
			.accessibilityIdentifier("settings.feedback")
			NavigationLink(
				model.phrasebook.say(Catalog.diagnosticsTitle), value: ShellDestination.diagnostics
			)
			.accessibilityIdentifier("settings.diagnostics")
			NavigationLink(model.phrasebook.say(Catalog.aboutTitle), value: ShellDestination.about)
				.accessibilityIdentifier("settings.about")
		}
	}
}
