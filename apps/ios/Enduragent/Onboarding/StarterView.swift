import EnduragentCoach
import SwiftUI

struct StarterView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				if let starterLine = model.starterLine {
					Text(starterLine)
						.accessibilityIdentifier("starter.credits")
				}
				if model.starterResolved {
					Button(model.phrasebook.say(Catalog.onboardingStarterStart, [:])) {
						Task { await model.startChatting() }
					}
					.accessibilityIdentifier("starter.start")
				} else {
					ProgressView(model.phrasebook.say(Catalog.onboardingStarterProgress, [:]))
						.accessibilityIdentifier("starter.progress")
				}
			}
			.padding()
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.task {
				await model.loadStarter()
			}
		}
	}
}
