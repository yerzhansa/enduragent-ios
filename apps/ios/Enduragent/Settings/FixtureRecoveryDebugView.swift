#if DEBUG
	import EnduragentCoachFixtures
	import SwiftUI

	struct FixtureRecoveryDebugView: View {
		var model: ShellModel
		@State private var failure: String?

		var body: some View {
			if let fixture = model.services.fixture {
				Button("Reject two overlapping OpenRouter requests") {
					Task {
						do {
							try await OpenRouterRejectionFixture.rejectTwoRequests(
								coach: model.services.coach, transport: fixture.transport)
						} catch { failure = String(describing: error) }
					}
				}
				.accessibilityIdentifier("fixture.rejectTwoRequests")
				if let failure { Text(failure).accessibilityIdentifier("fixture.rejectionFailure") }
			}
		}
	}
#endif
