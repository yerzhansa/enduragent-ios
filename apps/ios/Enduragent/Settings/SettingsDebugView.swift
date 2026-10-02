import EnduragentCoach
import SwiftUI

#if DEBUG
	struct SettingsDebugView: View {
		static let title = "Debug"
		var model: ShellModel

		var body: some View {
			List {
				NavigationLink("Credits", value: ShellDestination.debugCredits)
					.accessibilityIdentifier("debug.credits")
				NavigationLink("Records", value: ShellDestination.debugRecords)
					.accessibilityIdentifier("debug.records")
				NavigationLink(
					model.phrasebook.say(Catalog.settingsLanguageTitle, [:]),
					value: ShellDestination.debugLanguage
				)
				.accessibilityIdentifier("debug.language")
				NavigationLink(
					model.phrasebook.say(Catalog.settingsConversationTitle, [:]),
					value: ShellDestination.session
				)
				.accessibilityIdentifier("debug.session")
				NavigationLink("Leases", value: ShellDestination.debugLeases)
					.accessibilityIdentifier("debug.leases")
				if model.services.fixture != nil {
					FixtureCountsDebugView(model: model)
				}
			}
			.navigationTitle(Self.title)
		}
	}
#endif
