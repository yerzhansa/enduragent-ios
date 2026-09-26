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
					ForEach(model.chat?.turns ?? []) { turn in
						TurnRowView(model: model, turn: turn)
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
			.onChange(of: model.chat) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
		}
	}

	private var showsGreeting: Bool {
		model.chat?.turns.isEmpty ?? true
	}
}
