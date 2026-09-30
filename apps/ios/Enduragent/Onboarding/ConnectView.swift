import EnduragentCoach
import SwiftUI

struct ConnectView: View {
	@Bindable var model: ShellModel

	var body: some View {
		NavigationStack {
			Form {
				SecureField(
					model.phrasebook.say(Catalog.onboardingConnectApiKey, [:]),
					text: $model.connectKey
				)
				.accessibilityIdentifier("connect.apiKey")
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				Button(model.phrasebook.say(Catalog.onboardingConnectAction, [:])) {
					Task { await model.connect() }
				}
				.accessibilityIdentifier("connect.connect")
				if let connectError = model.connectError {
					Text(connectError)
						.accessibilityIdentifier("connect.error")
				}
				if !model.didConnect {
					Button(model.phrasebook.say(Catalog.onboardingConnectSkip, [:])) {
						model.skipConnect()
					}
					.accessibilityIdentifier("connect.skip")
				}
				if model.didConnect, let connected = model.connected {
					if let athleteName = connected.athleteName {
						Text(athleteName)
							.accessibilityIdentifier("connect.athleteName")
					}
					if let wellness = connected.today {
						Text(
							model.phrasebook.say(
								Catalog.onboardingConnectFitness,
								["value": wholeNumber(wellness.fitness)]
							)
						)
						.accessibilityIdentifier("connect.fitness")
						Text(
							model.phrasebook.say(
								Catalog.onboardingConnectFatigue,
								["value": wholeNumber(wellness.fatigue)]
							)
						)
						.accessibilityIdentifier("connect.fatigue")
						Text(
							model.phrasebook.say(
								Catalog.onboardingConnectForm, ["value": wholeNumber(wellness.form)]
							)
						)
						.accessibilityIdentifier("connect.form")
					}
					Button(model.phrasebook.say(Catalog.languageContinue, [:])) {
						model.continueConnect()
					}
					.accessibilityIdentifier("connect.continue")
				}
			}
		}
	}

	private func wholeNumber(_ value: Double?) -> String {
		guard let value else { return "—" }
		return String(Int(value.rounded()))
	}
}
