#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct CreditsDebugView: View {
		let coach: Coach
		let deviceCheck: any DeviceCheckTokenProviding
		let displayLocale: DisplayLocale
		@State private var balanceText = "—"
		@State private var starterMessage = ""
		@State private var errorText: String?
		@State private var identityText = "—"
		@State private var hasKey = false

		var body: some View {
			List {
				Section("Balance") {
					Text(balanceText)
				}
				Section("Starter") {
					Button("Get starter credits") {
						Task { await grantStarter() }
					}
					.accessibilityIdentifier("debug.credits.claimStarter")
					if !starterMessage.isEmpty {
						Text(starterMessage)
							.accessibilityIdentifier("debug.credits.starterNotice")
					}
				}
				if let errorText {
					Section("Error") {
						Text(errorText)
					}
				}
				Section("Identity") {
					Text(identityText)
						.font(.footnote.monospaced())
					Text(hasKey ? "Athlete key stored" : "No athlete key")
					Button("New athlete identity", role: .destructive) {
						Task { await newIdentity() }
					}
				}
			}
			.navigationTitle("Credits")
			.task { await reload() }
		}

		@MainActor
		private func refreshIdentity() async {
			do {
				let identity = try await coach.creditsIdentity()
				identityText = identity.appAccountToken?.uuidString ?? "—"
				hasKey = identity.hasCreditsKey
			} catch {
				present(error)
			}
		}

		@MainActor
		private func newIdentity() async {
			do {
				try await coach.replaceAppAccountToken()
				errorText = nil
			} catch {
				present(error)
			}
			await refreshIdentity()
		}

		@MainActor
		private func reload() async {
			await refreshIdentity()
			await refreshBalance()
		}

		@MainActor
		private func refreshBalance() async {
			do {
				let balance = try await coach.credits.balance()
				balanceText = "\(balance.credits.units) credits"
			} catch CreditsFailure.noAthleteKey {
				balanceText = "—"
			} catch {
				balanceText = "—"
				present(error)
			}
		}

		@MainActor
		private func grantStarter() async {
			do {
				let token = try await deviceCheck.token()
				let notice = await coach.claimStarter(deviceCheck: token)
				starterMessage = notice.sentence(in: displayLocale)
				errorText = nil
				await refreshBalance()
			} catch {
				present(error)
			}
		}

		@MainActor
		private func present(_ error: Error) {
			if let failure = error as? CreditsFailure {
				errorText = creditsFailureName(failure)
			} else if let unavailable = error as? AccessUnavailable {
				errorText = "keychain \(unavailable)"
			} else {
				errorText = error.localizedDescription
			}
		}
	}

	private func creditsFailureName(_ failure: CreditsFailure) -> String {
		switch failure {
		case .banned:
			"banned"
		case .notOurBundle:
			"notOurBundle"
		case .wrongEnvironment:
			"wrongEnvironment"
		case .unknownPack:
			"unknownPack"
		case .noPurchaseToRecover:
			"noPurchaseToRecover"
		case .identityMismatch:
			"identityMismatch"
		case .accountChanged:
			"accountChanged"
		case .rateLimited:
			"rateLimited"
		case .unavailable:
			"unavailable"
		case .unexpectedResponse:
			"unexpectedResponse"
		case .noAthleteKey:
			"noAthleteKey"
		case .athleteDeleted:
			"athleteDeleted"
		case .unauthorized:
			"unauthorized"
		}
	}
#endif
