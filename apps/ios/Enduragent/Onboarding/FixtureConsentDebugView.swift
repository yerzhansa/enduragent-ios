#if DEBUG
	import SwiftUI

	struct FixtureConsentDebugView: View {
		var model: ShellModel

		var body: some View {
			if let transport = model.services.fixtureTransport {
				Text("\(transport.requestCount) model requests")
					.accessibilityIdentifier("consent.modelRequestCount")
			}
		}
	}
#endif
