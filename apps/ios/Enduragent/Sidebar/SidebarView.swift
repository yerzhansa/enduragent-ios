import SwiftUI

struct SidebarView: View {
	@Bindable var model: ShellModel

	var body: some View {
		List {
			NavigationLink("Credits") {
				CreditsView(model: model)
			}
			.accessibilityIdentifier("sidebar.credits")
			NavigationLink("History") {
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
		.navigationTitle("Menu")
	}
}

#if DEBUG
	struct DebugMenuView: View {
		var model: ShellModel

		var body: some View {
			List {
				NavigationLink("Credits") {
					CreditsDebugView()
				}
				NavigationLink("Records") {
					RecordSyncDebugView(probe: model.services?.coach.recordSyncProbe())
				}
				.accessibilityIdentifier("debug.records")
				NavigationLink("Leases") {
					LeasesDebugView(leases: model.services?.leases)
				}
				.accessibilityIdentifier("debug.leases")
				if model.builder.isFixture {
					Text("\(FixtureBlockingURLProtocol.requestCount) requests")
						.accessibilityIdentifier("fixture.requestCount")
					Text(model.services?.fixtureTransport?.lastChatHistoryHead ?? "—")
						.accessibilityIdentifier("fixture.historyHead")
				}
			}
			.navigationTitle("Debug")
		}
	}
#endif
