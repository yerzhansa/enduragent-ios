#if DEBUG
	import SwiftUI

	struct FixtureCountsDebugView: View {
		var services: AppServices?

		var body: some View {
			Text("\(FixtureBlockingURLProtocol.requestCount) requests")
				.accessibilityIdentifier("fixture.requestCount")
			Text("\(services?.fixtureTransport?.requestCount ?? 0) model requests")
				.accessibilityIdentifier("fixture.modelRequestCount")
			Text(services?.fixtureTransport?.lastChatHistoryHead ?? "—")
				.accessibilityIdentifier("fixture.historyHead")
		}
	}
#endif
