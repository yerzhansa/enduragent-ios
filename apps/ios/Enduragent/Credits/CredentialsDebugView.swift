#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct CredentialsDebugView: View {
		var model: ShellModel
		@State private var key = ""
		@State private var outcome = ""
		@State private var locked = false

		var body: some View {
			List {
				Section("Connection") {
					Text(outcome.isEmpty ? "—" : outcome)
						.accessibilityIdentifier("credentials.outcome")
					Text(model.connected?.athleteName ?? "—")
						.accessibilityIdentifier("credentials.athlete")
					Text(connectionText)
						.font(.footnote.monospaced())
						.accessibilityIdentifier("credentials.connection")
					Text(model.connected.map { "Key ending \($0.keySuffix)" } ?? "No key")
						.font(.footnote)
						.accessibilityIdentifier("credentials.keySuffix")
				}
				Section("Change") {
					TextField("intervals.icu API key", text: $key)
						.accessibilityIdentifier("credentials.apiKey")
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
					HStack {
						action("Replace", "credentials.replace") {
							.replace(apiKey: key, athlete: .keyOwner)
						}
						action("Blank key", "credentials.replaceBlank") {
							.replace(apiKey: " ", athlete: .keyOwner)
						}
						action("Cancel", "credentials.cancel") { .keep }
					}
					HStack {
						action("Switch athlete", "credentials.switchAthlete") {
							.replaceConfirmingAthleteSwitch(apiKey: key, athlete: .keyOwner)
						}
						action("Disconnect", "credentials.disconnect") { .disconnect }
					}
					if let backing = model.services.fixtureDirector?.secretBacking {
						HStack {
							Button(locked ? "Unlock keychain" : "Lock keychain") {
								backing.locked.toggle()
								locked = backing.locked
								Task { await model.refreshStatus() }
							}
							.accessibilityIdentifier("credentials.lock")
							Spacer()
							Button("Fail next write") {
								backing.failNextWrite = true
								outcome = "The next keychain write fails."
							}
							.accessibilityIdentifier("credentials.failNextWrite")
						}
						.buttonStyle(.borderless)
					}
				}
			}
			.navigationTitle("Credentials")
			.navigationBarTitleDisplayMode(.inline)
			.task {
				locked = model.services.fixtureDirector?.secretBacking.locked ?? false
				await model.refreshStatus()
			}
		}

		private func action(
			_ title: String, _ identifier: String,
			_ intent: @escaping () -> IntervalsConnectionChange
		) -> some View {
			Button(title) {
				Task { await change(intent()) }
			}
			.buttonStyle(.borderless)
			.frame(maxWidth: .infinity)
			.accessibilityIdentifier(identifier)
		}

		private var connectionText: String {
			switch model.status?.training {
			case .connected(_, .intervals(let connection, let athlete))?:
				"\(connection.rawValue.uuidString) \(athlete?.rawValue ?? "unresolved")"
			case .connected(_, .unconnected)?, .unconnected?:
				"unconnected"
			case .unavailable(let unavailable)?:
				"unavailable \(unavailable)"
			case nil:
				"—"
			}
		}

		@MainActor
		private func change(_ change: IntervalsConnectionChange) async {
			outcome = describe(await model.services.coach.changeTraining(change))
			await model.refreshStatus()
		}

		private func describe(_ outcome: CredentialOutcome<IntervalsSummary>) -> String {
			switch outcome {
			case .kept, .refused(.blankReplacementKeepsCurrent):
				"Kept the current key."
			case .replaced(let summary, let authority):
				"Replaced. \(summary.athleteName ?? "Athlete unknown"), authority \(authority.map { "\($0)" } ?? "new")."
			case .disconnected:
				"Disconnected."
			case .refused(.differentAthlete(let current, let new)):
				"This key belongs to athlete \(new.rawValue), not \(current.rawValue). Switch athlete to use it."
			case .refused(.modelNotInCatalog):
				"Refused."
			case .failedPreviousKept:
				"Previous key kept."
			}
		}
	}
#endif
