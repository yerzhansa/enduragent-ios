import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 16) {
					if showsGreeting {
						Text(
							model.athleteFirstName.isEmpty
								? "Hello." : "Hello, \(model.athleteFirstName).")
					}
					ForEach(Array(model.seam.transcript.enumerated()), id: \.offset) { _, message in
						Text(message.text)
					}
					if model.isWaitingForCoach {
						Text(model.builder.phrasebook.say(Catalog.chatNoticeWorking, [:]))
							.foregroundStyle(.secondary)
							.accessibilityIdentifier("chat.working")
					}
					if !model.seam.streamingText.isEmpty {
						Text(model.seam.streamingText)
					}
					if let confirmLine = model.confirmLine {
						Text(confirmLine)
					}
					Color.clear
						.frame(height: 1)
						.id("transcript.tail")
				}
				.padding()
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.onChange(of: model.seam.streamingText) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
			.onChange(of: model.seam.transcript.count) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
		}
	}

	private var showsGreeting: Bool {
		model.seam.transcript.isEmpty && model.seam.streamingText.isEmpty
			&& model.seam.phase != .streaming
	}
}
