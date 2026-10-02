#if DEBUG
	import SwiftUI

	struct FixtureCountsDebugView: View {
		var services: AppServices

		var body: some View {
			if let fixture = services.fixture {
				Button("Fail next record append") { fixture.records.failNextAppend = true }
					.accessibilityIdentifier("fixture.failNextAppend")
				Button("Expire current lease") {
					Task { await fixture.host.expire(.systemExpired) }
				}
				.accessibilityIdentifier("fixture.expire")
			}
			Text("\(FixtureBlockingURLProtocol.requestCount) requests")
				.accessibilityIdentifier("fixture.requestCount")
			Text("\(services.fixtureTransport?.requestCount ?? 0) model requests")
				.accessibilityIdentifier("fixture.modelRequestCount")
			Text(services.fixtureTransport?.lastChatHistoryHead ?? "—")
				.accessibilityIdentifier("fixture.historyHead")
			Text(services.fixtureTransport?.lastReplyLanguage ?? "—")
				.accessibilityIdentifier("fixture.replyLanguage")
		}
	}
#endif
