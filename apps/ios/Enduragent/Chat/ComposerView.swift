import EnduragentCoach
import SwiftUI

struct ComposerView: View {
	@Bindable var model: ShellModel
	@FocusState private var composerFocused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				TextField(
					model.builder.phrasebook.say(Catalog.chatComposerMessageField, [:]),
					text: $model.composer
				)
				.accessibilityIdentifier("chat.composer")
				.textInputAutocapitalization(.sentences)
				.focused($composerFocused)
				.onChange(of: model.composer) {
					model.updateSlashList()
				}
				Button(model.builder.phrasebook.say(Catalog.chatComposerSendButton, [:])) {
					composerFocused = false
					Task { await model.send(model.composer) }
				}
				.accessibilityIdentifier("chat.send")
			}
			Text(model.builder.phrasebook.say(Catalog.chatViewDisclaimer, [:]))
				.font(.footnote)
		}
		.padding()
	}
}
