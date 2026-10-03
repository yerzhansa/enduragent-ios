import EnduragentCoach
import SwiftUI

struct StarterView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				Button {
					Task { await model.chooseAccess(.useCredits) }
				} label: {
					choice(Catalog.creditsTitle, selected: model.selectedAccessMethod == .credits)
				}
				.buttonStyle(.borderedProminent)
				.accessibilityIdentifier("starter.useCredits")
				.accessibilityAddTraits(model.selectedAccessMethod == .credits ? .isSelected : [])
				.disabled(!model.starterResolved || model.isChangingAccess)
				if let starterLine = model.starterLine {
					Text(starterLine)
						.accessibilityIdentifier("starter.credits")
				}
				Button {
					Task { await model.chooseAccess(.signInToOpenRouter) }
				} label: {
					choice(
						Catalog.accessSignIn,
						selected: model.selectedAccessMethod == .openRouterAccount)
				}
				.accessibilityIdentifier("starter.openRouter")
				.accessibilityAddTraits(
					model.selectedAccessMethod == .openRouterAccount ? .isSelected : []
				)
				.disabled(!model.starterResolved || model.isChangingAccess)
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

	private func choice(_ title: CatalogKey, selected: Bool) -> some View {
		HStack {
			Text(model.phrasebook.say(title))
			if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
		}
	}
}
