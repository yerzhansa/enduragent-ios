import EnduragentCoach
import SwiftUI

struct CreditsView: View {
	var model: ShellModel

	var body: some View {
		List {
			Section {
				if let balance = model.creditsBalanceLine {
					Text(balance)
						.accessibilityIdentifier("credits.balance")
				}
				if let notice = model.creditsNotice {
					Text(notice.sentence(in: model.displayLocale))
						.accessibilityIdentifier("credits.notice")
				}
			}
			Section {
				ForEach(model.creditOffers ?? []) { offer in
					offerRow(offer)
				}
				if model.creditOffers?.isEmpty == true {
					Text(AthleteNotice.creditsNotForSale.sentence(in: model.displayLocale))
						.accessibilityIdentifier("credits.notForSale")
				}
				if let notice = model.creditsPurchaseNotice {
					Text(notice.sentence(in: model.displayLocale))
						.accessibilityIdentifier("credits.purchaseNotice")
					ForEach(Array(notice.actions.enumerated()), id: \.offset) { _, action in
						Button(model.phrasebook.say(action.title, [:])) {
							Task { await model.perform(action) }
						}
						.accessibilityIdentifier("credits.purchaseAction")
					}
				}
			}
		}
		.navigationTitle(model.phrasebook.say(Catalog.creditsTitle, [:]))
		.task {
			await model.loadCredits()
		}
	}

	private func offerRow(_ offer: CreditsOffer) -> some View {
		HStack {
			Text(model.creditsPackLine(offer))
				.accessibilityIdentifier("credits.pack.\(offer.id)")
			Spacer()
			if model.purchasingCredits == offer.id {
				ProgressView()
			} else {
				Button(model.phrasebook.say(Catalog.creditsBuy, [:])) {
					Task { await model.buyCredits(offer) }
				}
				.buttonStyle(.bordered)
				.disabled(model.purchasingCredits != nil)
				.accessibilityIdentifier("credits.buy.\(offer.id)")
			}
		}
	}
}

extension ShellModel {
	var balance: Credits? { credits.balance }
	var creditsNotice: AthleteNotice? { credits.notice }
	var creditOffers: [CreditsOffer]? { credits.offers }
	var creditsPurchaseNotice: AthleteNotice? { credits.purchaseNotice }
	var purchasingCredits: CreditsOffer.ID? { credits.purchasing }

	func loadCredits() async {
		await credits.load()
	}

	func buyCredits(_ offer: CreditsOffer) async {
		await credits.buy(offer)
	}

	func askAppleForRefund(_ purchase: CreditsPurchase.ID) async {
		await credits.askAppleForRefund(purchase)
	}

	var creditsBalanceLine: String? {
		balance.map {
			displayLocale.say(
				Catalog.creditsBalance, count: $0.units, ["formattedCount": .integer($0.units)])
		}
	}

	func creditsPackLine(_ offer: CreditsOffer) -> String {
		let units = offer.pack.credits.units
		return displayLocale.say(
			Catalog.creditsPackPrice, count: units,
			["formattedCount": .integer(units), "price": .text(offer.displayPrice)])
	}
}
