import EnduragentCoach
import SwiftUI

struct AboutView: View {
	var model: ShellModel
	var support: SupportModel

	var body: some View {
		List {
			Section {
				Text(support.about.app.name)
					.accessibilityIdentifier("about.value.name")
				Text(
					model.phrasebook.say(
						Catalog.settingsApplicationVersion, ["version": support.about.app.display])
				)
				.accessibilityIdentifier("about.version")
				Link(destination: About.privacyPolicy) {
					Text(model.phrasebook.say(Catalog.aboutPrivacyPolicy))
				}
				.accessibilityIdentifier("about.privacyPolicy")
			}
		}
		.navigationTitle(model.phrasebook.say(Catalog.aboutTitle))
		.navigationBarTitleDisplayMode(.inline)
	}
}
