import SwiftUI

struct ConnectView: View {
	@Bindable var model: ShellModel

	var body: some View {
		NavigationStack {
			Form {
				TextField("intervals.icu API key", text: $model.connectKey)
					.accessibilityIdentifier("connect.apiKey")
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
				Button("Connect") {
					Task { await model.connect() }
				}
				.accessibilityIdentifier("connect.connect")
				if let connectError = model.connectError {
					Text(connectError)
				}
				if !model.didConnect {
					Button("Skip for now") {
						model.skipConnect()
					}
					.accessibilityIdentifier("connect.skip")
				}
				if model.didConnect, let athlete = model.athlete {
					Text(athlete.name)
						.accessibilityIdentifier("connect.athleteName")
					if let wellness = model.todayWellness {
						Text("Fitness \(wholeNumber(wellness.fitness))")
							.accessibilityIdentifier("connect.fitness")
						Text("Fatigue \(wholeNumber(wellness.fatigue))")
							.accessibilityIdentifier("connect.fatigue")
						Text("Form \(wholeNumber(wellness.form))")
							.accessibilityIdentifier("connect.form")
					}
					Button("Continue") {
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
