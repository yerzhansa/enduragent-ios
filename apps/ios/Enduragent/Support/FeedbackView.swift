import EnduragentCoach
import SwiftUI

struct FeedbackView: View {
	var model: ShellModel
	@Bindable var support: SupportModel

	var body: some View {
		let line = support.line
		Form {
			Section {
				Text(say(Catalog.feedbackPrompt))
					.accessibilityIdentifier("feedback.prompt")
				TextField(text: $support.draft, axis: .vertical) {
					Text(say(Catalog.feedbackTitle))
				}
				.lineLimit(4...)
				.accessibilityIdentifier("feedback.field")
			}
			Section {
				if let sentence = line.sentence {
					Text(model.displayLocale.say(sentence, line.arguments))
						.accessibilityIdentifier("feedback.outcome")
				}
				button(line.button)
			}
		}
		.navigationTitle(say(Catalog.feedbackTitle))
		.navigationBarTitleDisplayMode(.inline)
		.task { await support.appear() }
	}

	@ViewBuilder
	private func button(_ kind: FeedbackButton) -> some View {
		switch kind {
		case .send, .sending:
			Button {
				Task { await support.send() }
			} label: {
				Text(say(Catalog.feedbackSend)).frame(maxWidth: .infinity)
			}
			.disabled(kind == .sending)
			.accessibilityIdentifier("feedback.send")
		case .tryAgain:
			Button {
				Task { await support.tryAgain() }
			} label: {
				Text(say(Catalog.chatTranscriptRetry)).frame(maxWidth: .infinity)
			}
			.accessibilityIdentifier("feedback.tryAgain")
		}
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}
