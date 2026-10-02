import EnduragentCoach
import SwiftUI

struct TrainingSettingsView: View {
	var model: ShellModel
	@Bindable var settings: TrainingSettingsModel

	var body: some View {
		Form {
			Section {
				TrainingConnectionResultView(
					model: model, identifierPrefix: "training",
					athleteIdentifier: "training.athlete")
			}
			Section {
				if settings.isEditing {
					IntervalsKeyField(phrasebook: model.phrasebook, text: $settings.key)
						.accessibilityIdentifier("training.apiKey")
					Button(
						say(
							model.connected == nil
								? Catalog.onboardingConnectAction : Catalog.settingsTrainingReplace)
					) {
						Task { await settings.replace() }
					}
					.accessibilityIdentifier("training.save")
					Button(say(Catalog.commonCancel), role: .cancel) {
						Task { await settings.keep() }
					}
					.accessibilityIdentifier("training.cancel")
				} else {
					Button(
						say(
							model.connected == nil
								? Catalog.onboardingConnectAction : Catalog.settingsTrainingReplace)
					) {
						settings.edit()
					}
					.accessibilityIdentifier("training.edit")
				}
				if model.connected != nil {
					Button(say(Catalog.settingsTrainingKeep)) {
						Task { await settings.keep() }
					}
					.accessibilityIdentifier("training.keep")
					Button(say(Catalog.settingsTrainingDisconnect), role: .destructive) {
						settings.requestDisconnect()
					}
					.accessibilityIdentifier("training.disconnect")
				}
			}
			.disabled(settings.isSaving)
			if settings.isSaving { ProgressView() }
		}
		.navigationTitle(say(Catalog.settingsTrainingTitle))
		.navigationBarTitleDisplayMode(.inline)
		.modifier(TrainingConnectionConfirmation(model: model, settings: settings))
		.onDisappear { settings.dismiss() }
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}
