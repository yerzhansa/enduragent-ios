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
				Button("Start chatting") {
					model.startChatting()
				}
				.accessibilityIdentifier("starter.start")
			}
			.padding()
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.task {
				await model.loadStarter()
			}
		}
	}
}
