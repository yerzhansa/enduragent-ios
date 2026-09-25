#if DEBUG
	import EnduragentCoach
	import StoreKit
	import SwiftUI

	struct CreditsDebugView: View {
		@State private var session: CreditsDebugSession?
		@State private var balanceText = "—"
		@State private var starterMessage = ""
		@State private var catalog: PackCatalog?
		@State private var products: [String: Product] = [:]
		@State private var errorText: String?
		@State private var identityText = "—"
		@State private var hasKey = false

		var body: some View {
			NavigationStack {
				List {
					Section("Balance") {
						Text(balanceText)
					}
					Section("Starter") {
						Button("Get starter credits") {
							Task { await grantStarter() }
						}
						if !starterMessage.isEmpty {
							Text(starterMessage)
						}
					}
					Section {
						if let catalog {
							ForEach(catalog.packs) { pack in
								HStack {
									Text("\(pack.credits.units) credits")
									Spacer()
									let product = products[pack.id]
									Button(product?.displayPrice ?? "Buy") {
										if let product {
											Task { await buy(product) }
										}
									}
									.disabled(!catalog.purchasesEnabled || product == nil)
								}
							}
						}
					} header: {
						Text("Packs")
					} footer: {
						if catalog?.purchasesEnabled == false {
							Text("testers cannot buy packs yet")
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
							newIdentity()
						}
					}
				}
				.navigationTitle("Credits")
				.task { await bootstrap() }
			}
		}

		@MainActor
		private func bootstrap() async {
			if session == nil {
				session = CreditsDebugSession { errorText = $0 }
			}
			await reload()
		}

		@MainActor
		private func refreshIdentity() {
			guard let session else { return }
			do {
				identityText = try session.secrets.appAccountToken().uuidString
				hasKey = try session.secrets.openRouterKey() != nil
			} catch {
				present(error)
			}
		}

		@MainActor
		private func newIdentity() {
			guard let session else { return }
			do {
				try session.secrets.storeAppAccountToken(UUID())
				errorText = nil
			} catch {
				present(error)
			}
			refreshIdentity()
		}

		@MainActor
		private func reload() async {
			guard let session else { return }
			refreshIdentity()
			do {
				let loaded = try await session.credits.catalog()
				catalog = loaded
				let loadedProducts = try await Product.products(for: loaded.packs.map(\.id))
				products = Dictionary(uniqueKeysWithValues: loadedProducts.map { ($0.id, $0) })
				errorText = nil
			} catch {
				present(error)
			}
			await refreshBalance()
		}

		@MainActor
		private func refreshBalance() async {
			guard let session, let scale = catalog?.scale else {
				balanceText = "—"
				return
			}
			do {
				let balance = try await session.credits.balance(scale: scale)
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
			guard let session else { return }
			do {
				let token = try await session.deviceCheck.token()
				let outcome = try await session.credits.grant(deviceCheck: token)
				let hasKey = try session.secrets.openRouterKey() != nil
				switch outcome {
				case .minted:
					starterMessage = "Start chatting"
				case .alreadyGranted:
					starterMessage =
						hasKey
						? "Start chatting"
						: "This device already used its starter credits."
				case .toppedUp(let added):
					starterMessage = "Added \(added.units) credits"
				}
				errorText = nil
				await refreshBalance()
			} catch {
				present(error)
			}
		}

		@MainActor
		private func buy(_ product: Product) async {
			guard let session else { return }
			do {
				_ = try await session.purchases.purchase(product)
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
			} else if let keychain = error as? KeychainStoreError {
				errorText = "keychain \(keychain.status)"
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
		case .purchasesDisabled:
			"purchasesDisabled"
		case .noPurchaseToRecover:
			"noPurchaseToRecover"
		case .identityMismatch:
			"identityMismatch"
		case .rateLimited:
			"rateLimited"
		case .unavailable:
			"unavailable"
		case .unexpectedResponse:
			"unexpectedResponse"
		case .noAthleteKey:
			"noAthleteKey"
		}
	}

	@MainActor
	private final class CreditsDebugSession {
		let secrets: ICloudKeychainStore
		let credits: PhoneCreditsClient
		let purchases: StoreKitPurchaseCoordinator
		let deviceCheck = DeviceCheckTokenProvider()

		private static let workerBase: URL = {
			guard
				let url = URL(
					string: "https://enduragent-credits-testflight.yerzhan-st.workers.dev")
			else {
				fatalError(
					"https://enduragent-credits-testflight.yerzhan-st.workers.dev is invalid")
			}
			return url
		}()

		init(onSettlementFailure: @escaping @MainActor (String) -> Void) {
			let secrets = ICloudKeychainStore()
			self.secrets = secrets
			let credits = PhoneCreditsClient(
				secrets: secrets,
				workerBase: Self.workerBase
			)
			self.credits = credits
			self.purchases = StoreKitPurchaseCoordinator(
				credits: credits,
				secrets: secrets,
				onSettlementFailure: onSettlementFailure
			)
		}
	}
#endif
