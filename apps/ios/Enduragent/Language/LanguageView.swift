import EnduragentCoach
import SwiftUI

struct LanguageView: View {
	@Bindable var model: ShellModel

	var body: some View {
		List {
			if let line = model.languageNotSavedLine {
				Section {
					Text(line)
						.accessibilityIdentifier("language.saveFailed")
				}
			}
			Section {
				ForEach(LanguagePreference.choices) { choice in
					Button {
						Task { await model.chooseLanguage(choice) }
					} label: {
						HStack {
							Text(choice.title(in: model.phrasebook))
								.foregroundStyle(Color.primary)
							Spacer()
							if choice == current {
								Image(systemName: "checkmark")
									.foregroundStyle(.tint)
									.accessibilityHidden(true)
							}
						}
					}
					.accessibilityIdentifier("language.choice.\(choice.id)")
					.accessibilityAddTraits(choice == current ? .isSelected : [])
				}
			}
		}
		.navigationTitle(model.phrasebook.say(Catalog.languageChooseTitle, [:]))
		.navigationBarTitleDisplayMode(.inline)
		.task { await model.refreshStatus() }
	}

	private var current: LanguagePreference {
		model.status?.language ?? .automatic
	}
}
