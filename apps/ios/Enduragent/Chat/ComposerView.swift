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
					Button {
						Task { await model.stop() }
					} label: {
						Label(say(Catalog.chatComposerStop), systemImage: "stop.fill")
					}
					.labelStyle(.iconOnly)
					.accessibilityIdentifier("chat.stop")
					.disabled(model.chat?.activity == .stopping)
				}
				Button {
					composerFocused = false
					Task { await model.send() }
				} label: {
					Label(say(Catalog.chatComposerSend), systemImage: "arrow.up.circle.fill")
				}
				.labelStyle(.iconOnly)
				.accessibilityIdentifier("chat.send")
				.disabled(model.isSending)
			}
			if model.notSent {
				Text(say(Catalog.chatComposerNotSent))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.composer.notSent")
			}
			if let notice = model.status?.notice {
				Text(notice.sentence(in: model.phrasebook))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.composer.notice")
			}
			Text(say(Catalog.chatViewDisclaimer))
				.font(.footnote)
		}
		.padding()
		.background(.background)
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("chat.composer.container")
		.onChange(of: model.navigation.isEmpty) { _, isEmpty in
			if !isEmpty { composerFocused = false }
		}
	}

	private func say(_ key: CatalogKey) -> String {
		model.phrasebook.say(key, [:])
	}
}
