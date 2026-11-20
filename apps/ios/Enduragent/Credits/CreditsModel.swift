import EnduragentCoach
import Observation

@MainActor
@Observable
final class CreditsModel {
	private(set) var balance: Credits?
	private(set) var notice: AthleteNotice?
	private(set) var offers: [CreditsOffer]?
	private(set) var purchaseNotice: AthleteNotice?
	private(set) var purchasing: CreditsOffer.ID?
	private let services: AppServices
	private var settling: Task<Void, Never>?

	init(services: AppServices) {
		self.services = services
		settling = Task { [weak self, coach = services.coach, store = services.store] in
			for await purchase in store.purchases() {
				let settled = await coach.settleCreditsPurchase(purchase, in: store)
				guard let self else { return }
				if let settled { purchaseNotice = settled }
				await refreshBalance()
			}
		}
	}

	isolated deinit {
		settling?.cancel()
	}

	func load() async {
		balance = nil
		notice = nil
		offers = nil
		if purchasing == nil, purchaseNotice?.actions.isEmpty ?? true { purchaseNotice = nil }
		await refreshBalance()
		offers = await services.coach.creditsOffers(in: services.store)
	}

	func buy(_ offer: CreditsOffer) async {
		guard purchasing == nil else { return }
		purchasing = offer.id
		purchaseNotice = nil
		purchaseNotice = await services.coach.buyCredits(offer, in: services.store)
		purchasing = nil
		await refreshBalance()
	}

	func askAppleForRefund(_ purchase: CreditsPurchase.ID) async {
		let request = await services.coach.requestCreditsRefund(for: purchase, in: services.store)
		if request == .submitted { purchaseNotice = nil }
	}

	private func refreshBalance() async {
		do {
			let held = try await services.coach.credits.balance()
			balance = held.credits
			notice = held.notice
		} catch {
			balance = nil
			notice = AthleteNotice.credits(failure: error)
		}
	}
}
