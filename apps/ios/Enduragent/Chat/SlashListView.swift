import EnduragentCoach
import SwiftUI

enum VisibleSlash {
	static let commands: [SlashCommand] = SlashCommand.all.filter { $0 != .plan }
}

struct SlashListView: View {
	var model: ShellModel

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(VisibleSlash.commands, id: \.self) { command in
				Button(command.rawValue) {
					model.fillSlash(command)
				}
				.accessibilityIdentifier("chat.slash.\(String(command.rawValue.dropFirst()))")
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal)
				.padding(.vertical, 10)
			}
		}
	}
}
