#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct FixtureSignInDebugView: View {
		var model: ShellModel
		@State private var authorizations = 0

		var body: some View {
			if let fixture = model.services.fixture, fixture.signInOutcome == .held,
				model.isChangingAccess
			{
				Text("\(authorizations) authorizations")
					.accessibilityIdentifier("fixture.signInCount")
				Button("Complete held sign-in") {
					Task {
						authorizations = await fixture.openRouterAuthorizer.requests.count
						guard authorizations == 1 else { return }
						await fixture.openRouterAuthorizer.complete(
							.success(OpenRouterAuthCode(code: "fixture-code")), at: 0)
					}
				}
				.accessibilityIdentifier("fixture.completeSignIn")
				.task {
					let deadline = ContinuousClock.now + .seconds(30)
					while authorizations == 0, ContinuousClock.now < deadline, !Task.isCancelled {
						authorizations = await fixture.openRouterAuthorizer.requests.count
						await Task.yield()
					}
				}
			}
		}
	}
#endif
