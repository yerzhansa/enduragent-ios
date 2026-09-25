import EnduragentCoach
import SwiftUI

struct ConnectView: View {
	@Bindable var model: ShellModel

	var body: some View {
		NavigationStack {
			Form {
				TextField(
					model.builder.phrasebook.say(Catalog.onboardingConnectApiKey, [:]),
					text: $model.connectKey
				)
				.accessibilityIdentifier("connect.apiKey")
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				Button(model.builder.phrasebook.say(Catalog.onboardingConnectAction, [:])) {
					Task { await model.connect() }
				}
				.accessibilityIdentifier("connect.connect")
				if let connectError = model.connectError {
					Text(connectError)
				}
				if !model.didConnect {
					Button(model.builder.phrasebook.say(Catalog.onboardingConnectSkip, [:])) {
						model.skipConnect()
					}
					.accessibilityIdentifier("connect.skip")
				}
				if model.didConnect, let athlete = model.athlete {
					Text(athlete.name)
						.accessibilityIdentifier("connect.athleteName")
					if let wellness = model.todayWellness {
						Text(
							model.builder.phrasebook.say(
								Catalog.onboardingConnectFitness,
								["value": wholeNumber(wellness.fitness)]
							)
						)
						.accessibilityIdentifier("connect.fitness")
						Text(
							model.builder.phrasebook.say(
								Catalog.onboardingConnectFatigue,
								["value": wholeNumber(wellness.fatigue)]
							)
						)
						.accessibilityIdentifier("connect.fatigue")
						Text(
							model.builder.phrasebook.say(
								Catalog.onboardingConnectForm, ["value": wholeNumber(wellness.form)]
							)
						)
						.accessibilityIdentifier("connect.form")
					}
					Button(model.builder.phrasebook.say(Catalog.commonContinue, [:])) {
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
