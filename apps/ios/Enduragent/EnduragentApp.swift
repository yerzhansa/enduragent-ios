import SwiftUI

@main
struct EnduragentApp: App {
	var body: some Scene {
		WindowGroup {
			#if DEBUG
			TabView {
				CreditsDebugView()
					.tabItem { Text("Credits") }
				RecordSyncDebugView()
					.tabItem { Text("Records") }
			}
			#else
			EmptyView()
			#endif
		}
	}
}
