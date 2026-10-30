import EnduragentCoach
import SwiftUI

struct ErasingView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			Form {
				Section {
					if model.yourData.phase == .deleting {
						ProgressView()
							.frame(maxWidth: .infinity)
							.accessibilityIdentifier("yourData.progress")
					}
					if let line = model.yourData.line {
						Text(say(line))
							.accessibilityIdentifier("yourData.outcome")
					}
				}
				actions
			}
			.navigationTitle(say(Catalog.yourDataDeleteEverything))
			.navigationBarTitleDisplayMode(.inline)
		}
	}

	@ViewBuilder
	private var actions: some View {
		switch model.yourData.phase {
		case .idle, .deleting:
			EmptyView()
		case .finished(.done), .finished(.iCloudLater):
			Section {
				action(Catalog.commonContinue, "yourData.continue") { model.yourData.finish() }
			}
		case .finished(.notStarted), .busy:
			Section {
				action(Catalog.chatTranscriptRetry, "yourData.tryAgain") {
					Task { await model.yourData.tryAgain() }
				}
				action(Catalog.commonCancel, "yourData.cancel") { model.cancelErasure() }
			}
		case .finished(.notFinished):
			Section {
				action(Catalog.chatTranscriptRetry, "yourData.tryAgain") {
					Task { await model.yourData.tryAgain() }
				}
			}
		}
	}

	private func action(_ key: CatalogKey, _ identifier: String, _ perform: @escaping () -> Void)
		-> some View
	{
		Button(action: perform) {
			Text(say(key)).frame(maxWidth: .infinity)
		}
		.accessibilityIdentifier(identifier)
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}
