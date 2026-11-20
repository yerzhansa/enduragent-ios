import EnduragentCoach
import SwiftUI

struct StarterView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				if let starterLine = model.starterLine {
					Text(starterLine)
						.multilineTextAlignment(.center)
						.accessibilityIdentifier("starter.credits")
				}
				if model.starterResolved {
					Button(model.phrasebook.say(Catalog.onboardingStarterStart, [:])) {
						Task { await model.startChatting() }
					}
					.buttonStyle(.borderedProminent)
					.accessibilityIdentifier("starter.start")
				} else {
					ProgressView(model.phrasebook.say(Catalog.onboardingStarterProgress, [:]))
						.accessibilityIdentifier("starter.progress")
				}
			}
			.padding()
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.navigationTitle(model.phrasebook.say(Catalog.creditsTitle, [:]))
			.task {
				await model.loadStarter()
			}
		}
	}
}
