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
						.accessibilityIdentifier("connect.error")
				}
				if !model.didConnect {
					Button("Skip for now") {
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
