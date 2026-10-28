import EnduragentCoach
import SwiftUI

struct FeedbackView: View {
	var model: ShellModel
	@Bindable var support: SupportModel
	@FocusState private var editing: Bool

	var body: some View {
		let line = support.line
		ScrollView {
			VStack(spacing: 32) {
				card {
					Text(say(Catalog.feedbackPrompt))
						.accessibilityIdentifier("feedback.prompt")
					Divider()
					TextField(text: $support.draft, axis: .vertical) {
						Text(say(Catalog.feedbackTitle))
					}
					.lineLimit(4, reservesSpace: true)
					.focused($editing)
					.accessibilityIdentifier("feedback.field")
				}
				card {
					if let sentence = line.sentence {
						Text(model.displayLocale.say(sentence, line.arguments))
							.accessibilityIdentifier("feedback.outcome")
						Divider()
					}
					button(line.button)
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 24)
		}
		.background(Color(.systemGroupedBackground))
		.navigationTitle(say(Catalog.feedbackTitle))
		.navigationBarTitleDisplayMode(.inline)
		.task { await support.appear() }
	}

	private func card(@ViewBuilder _ rows: () -> some View) -> some View {
		VStack(alignment: .leading, spacing: 12) { rows() }
			.padding(16)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
	}

	@ViewBuilder
	private func button(_ kind: FeedbackButton) -> some View {
		switch kind {
		case .send, .sending:
			Button {
				editing = false
				Task { await support.send() }
			} label: {
				Text(say(Catalog.feedbackSend)).frame(maxWidth: .infinity)
					.contentShape(.rect)
			}
			.disabled(kind == .sending)
			.accessibilityIdentifier("feedback.send")
		case .tryAgain:
			Button {
				editing = false
				Task { await support.tryAgain() }
			} label: {
				Text(say(Catalog.chatTranscriptRetry)).frame(maxWidth: .infinity)
					.contentShape(.rect)
			}
			.accessibilityIdentifier("feedback.tryAgain")
		}
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}
