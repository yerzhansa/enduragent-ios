import EnduragentCoach
import SwiftUI

struct AboutView: View {
	var model: ShellModel
	var support: SupportModel
	@Environment(\.dynamicTypeSize) private var textSize

	var body: some View {
		List {
			Section {
				Text(support.about.app.name)
					.accessibilityIdentifier("about.value.name")
				version
				Link(destination: About.privacyPolicy) {
					Text(model.phrasebook.say(Catalog.aboutPrivacyPolicy))
				}
				.accessibilityIdentifier("about.privacyPolicy")
			}
		}
		.navigationTitle(model.phrasebook.say(Catalog.aboutTitle))
		.navigationBarTitleDisplayMode(.inline)
	}

	@ViewBuilder
	private var version: some View {
		let label = Text(model.phrasebook.say(Catalog.aboutVersion))
			.accessibilityIdentifier("about.version")
		let value = Text(support.about.app.display)
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("about.value.version")
		if textSize.isAccessibilitySize {
			VStack(alignment: .leading, spacing: 2) {
				label
				value
			}
		} else {
			HStack(alignment: .firstTextBaseline) {
				label
				Spacer()
				value
			}
		}
	}
}
