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
					Button("Start chatting") {
						model.startChatting()
					}
					.accessibilityIdentifier("starter.start")
				} else {
					ProgressView("Requesting starter credits")
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
