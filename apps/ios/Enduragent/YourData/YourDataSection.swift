import EnduragentCoach
import SwiftUI

struct YourDataSection: View {
	var model: ShellModel

	var body: some View {
		Section(model.phrasebook.say(Catalog.yourDataTitle)) {
			NavigationLink(
				model.phrasebook.say(Catalog.yourDataDeleteEverything),
				value: ShellDestination.yourData
			)
			.accessibilityIdentifier("settings.yourData")
		}
	}
}
