import EnduragentCoach
import SwiftUI

struct StarterView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				method(Catalog.creditsTitle, .credits, choosing: .useCredits)
					.accessibilityIdentifier("starter.useCredits")
					.disabled(!model.starterResolved || model.isChangingAccess)
				if let starterLine = model.starterLine {
					Text(starterLine)
						.multilineTextAlignment(.center)
						.accessibilityIdentifier("starter.credits")
				}
				method(Catalog.accessSignIn, .openRouterAccount, choosing: .signInToOpenRouter)
					.accessibilityIdentifier("starter.openRouter")
					.disabled(!model.starterResolved)
				#if DEBUG
					FixtureSignInDebugView(model: model)
				#endif
				if model.starterResolved {
					Button(model.phrasebook.say(Catalog.onboardingStarterStart, [:])) {
						Task { await model.startChatting() }
					}
					.accessibilityIdentifier("starter.start")
					.disabled(model.isChangingAccess)
				} else {
					ProgressView(model.phrasebook.say(Catalog.onboardingStarterProgress, [:]))
						.accessibilityIdentifier("starter.progress")
				}
			}
			.padding()
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.navigationTitle(model.phrasebook.say(Catalog.accessTitle))
			.task {
				await model.loadStarter()
			}
		}
	}

	@ViewBuilder
	private func method(
		_ title: CatalogKey, _ method: AccessMethod, choosing change: ModelAccessChange
	) -> some View {
		let chosen = model.selectedAccessMethod == method
		let button = Button {
			Task { await model.chooseAccess(change) }
		} label: {
			HStack {
				Text(model.phrasebook.say(title))
				if chosen { Image(systemName: "checkmark").accessibilityHidden(true) }
			}
		}
		.accessibilityAddTraits(chosen ? .isSelected : [])
		if chosen {
			button.buttonStyle(.borderedProminent)
		} else {
			button
		}
	}
}
