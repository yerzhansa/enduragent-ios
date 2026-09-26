import EnduragentCoach
import SwiftUI

struct ComposerView: View {
	@Bindable var model: ShellModel
	@FocusState private var composerFocused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				TextField(say(Catalog.chatComposerMessagePlaceholder), text: $model.draft.text)
					.accessibilityIdentifier("chat.composer")
					.textInputAutocapitalization(.sentences)
					.focused($composerFocused)
					.onChange(of: model.draft.text) { previous, _ in
						model.draftChanged(from: previous)
					}
				if model.isWorking {
					Button(say(Catalog.chatComposerStop)) {
						Task { await model.stop() }
					}
					.accessibilityIdentifier("chat.stop")
					.disabled(model.chat?.activity == .stopping)
				}
				Button(say(Catalog.chatComposerSend)) {
					composerFocused = false
					Task { await model.send() }
				}
				.accessibilityIdentifier("chat.send")
			}
			if model.notSent {
				Text(say(Catalog.chatComposerNotSent))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.composer.notSent")
			}
			Text(say(Catalog.chatViewDisclaimer))
				.font(.footnote)
		}
		.padding()
	}

	private func say(_ key: CatalogKey) -> String {
		model.builder.phrasebook.say(key, [:])
	}
}
