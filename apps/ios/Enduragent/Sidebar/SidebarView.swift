import EnduragentCoach
import SwiftUI

struct SidebarView: View {
	@Bindable var model: ShellModel

	var body: some View {
		List {
			NavigationLink(model.phrasebook.say(Catalog.creditsTitle, [:])) {
				CreditsView(model: model)
			}
			.accessibilityIdentifier("sidebar.credits")
			NavigationLink(model.phrasebook.say(Catalog.archiveHistory, [:])) {
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
		.navigationTitle(model.phrasebook.say(Catalog.chatMenu, [:]))
	}
}

#if DEBUG
	struct DebugMenuView: View {
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
				if model.builder.isFixture {
					FixtureCountsDebugView(services: model.services)
				}
			}
			.navigationTitle("Debug")
		}
	}
#endif
