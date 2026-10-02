import EnduragentCoach
import SwiftUI

struct ConnectView: View {
	@Bindable var model: ShellModel

	var body: some View {
		NavigationStack {
			Form {
				TrainingConnectionResultView(
					model: model, identifierPrefix: "connect",
					athleteIdentifier: "connect.athleteName")
				if model.trainingSettings.isEditing || !model.didConnect {
					IntervalsKeyField(phrasebook: model.phrasebook, text: $model.connectKey)
						.accessibilityIdentifier("connect.apiKey")
					Button(model.phrasebook.say(Catalog.onboardingConnectAction)) {
						Task { await model.connect() }
					}
					.accessibilityIdentifier("connect.connect")
				}
				if model.didConnect {
					Button(model.phrasebook.say(Catalog.languageContinue)) {
						model.continueConnect()
					}
					.accessibilityIdentifier("connect.continue")
				} else {
					Button(model.phrasebook.say(Catalog.onboardingConnectSkip, [:])) {
						model.skipConnect()
					}
					.accessibilityIdentifier("connect.skip")
				}
				if model.trainingSettings.isSaving { ProgressView() }
			}
			.disabled(model.trainingSettings.isSaving)
			.modifier(
				TrainingConnectionConfirmation(model: model, settings: model.trainingSettings))
		}
	}
}
