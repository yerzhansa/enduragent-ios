import EnduragentCoach
import SwiftUI

struct TranscriptView: View {
	@Bindable var model: ShellModel

	var body: some View {
		ScrollViewReader { proxy in
			List {
				Group {
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
				}
				.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
				Color.clear
					.frame(height: 1)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.id("transcript.tail")
			}
			.listStyle(.plain)
			.environment(\.defaultMinListRowHeight, 0)
			.buttonStyle(.borderless)
			.onChange(of: model.chat) {
				proxy.scrollTo("transcript.tail", anchor: .bottom)
			}
		}
	}

	private var showsGreeting: Bool {
		model.chat?.turns.isEmpty ?? true
	}
}
