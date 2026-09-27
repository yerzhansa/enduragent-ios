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
					notes(after: nil)
					ForEach(model.chat?.turns ?? []) { turn in
						TurnRowView(model: model, turn: turn)
						notes(after: turn.id)
					}
					Color.clear
						.frame(height: 1)
						.id("transcript.tail")
				}
				.padding()
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.onChange(of: model.chat) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
		}
	}

	private func notes(after turn: TurnID?) -> some View {
		ForEach((model.chat?.notes ?? []).filter { $0.after == turn }) { note in
			Text(note.notice.sentence(in: model.builder.phrasebook))
				.accessibilityIdentifier("chat.note")
		}
	}

	private var showsGreeting: Bool {
		model.chat?.turns.isEmpty ?? true
	}
}
