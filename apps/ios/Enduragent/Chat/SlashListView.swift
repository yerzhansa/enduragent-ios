import EnduragentCoach
import SwiftUI

struct SlashListView: View {
	var model: ShellModel

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(SlashCommand.allCases, id: \.self) { command in
				Button {
					model.fillSlash(command)
				} label: {
					VStack(alignment: .leading, spacing: 2) {
						Text(command.rawValue)
						Text(model.builder.phrasebook.say(command.menuTitle, [:]))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}
				.accessibilityIdentifier("chat.slash.\(String(command.rawValue.dropFirst()))")
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal)
				.padding(.vertical, 10)
			}
		}
	}
}
