import EnduragentCoach
import SwiftUI

#if DEBUG
	struct DebugMenuView: View {
		static let title = "Debug"
		var model: ShellModel

		var body: some View {
			List {
				NavigationLink("Credits") {
					CreditsDebugView(coach: model.services.coach)
				}
				NavigationLink("Credentials") {
					CredentialsDebugView(model: model)
				}
				.accessibilityIdentifier("debug.credentials")
				NavigationLink("Records") {
					RecordSyncDebugView(probe: model.services.coach.recordSyncProbe())
				}
				.accessibilityIdentifier("debug.records")
				NavigationLink(model.phrasebook.say(Catalog.settingsLanguageTitle, [:])) {
					LanguageView(model: model)
				}
				.accessibilityIdentifier("debug.language")
				NavigationLink(model.phrasebook.say(Catalog.settingsConversationTitle, [:])) {
					SessionDebugView(model: model)
				}
				.accessibilityIdentifier("debug.session")
				NavigationLink("Leases") {
					LeasesDebugView(leases: model.services.leases)
				}
				.accessibilityIdentifier("debug.leases")
				if model.environment.isFixture {
					FixtureCountsDebugView(services: model.services)
				}
			}
			.navigationTitle(Self.title)
		}
	}
#endif
