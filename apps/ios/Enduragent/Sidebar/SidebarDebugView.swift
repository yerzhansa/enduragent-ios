#if DEBUG
	import SwiftUI

	struct DebugMenuView: View {
		var model: ShellModel

		var body: some View {
			List {
				NavigationLink("Credits") {
					CreditsDebugView()
				}
				NavigationLink("Records") {
					RecordSyncDebugView()
				}
				if model.builder.isFixture {
					Text("\(FixtureBlockingURLProtocol.requestCount) requests")
						.accessibilityIdentifier("fixture.requestCount")
				}
			}
			.navigationTitle("Debug")
		}
	}
#endif
