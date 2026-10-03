import EnduragentCoach
import SwiftUI

struct CreditsView: View {
	var model: ShellModel

	var body: some View {
		List {
			if let balance = model.creditsBalanceLine {
				Text(balance)
					.accessibilityIdentifier("credits.balance")
			}
			if let catalog = model.catalog {
				ForEach(catalog.packs) { pack in
					HStack {
						Text(model.creditsPackLine(pack))
						Spacer()
						Button(model.phrasebook.say(Catalog.creditsBuy, [:])) {}
							.disabled(true)
					}
					.accessibilityIdentifier("credits.pack.\(pack.id)")
				}
			}
			Text(model.phrasebook.say(Catalog.creditsTesters, [:]))
				.accessibilityIdentifier("credits.note")
			if let notice = model.creditsNotice {
				Text(notice.sentence(in: model.displayLocale))
					.accessibilityIdentifier("credits.notice")
			}
		}
		.navigationTitle(model.phrasebook.say(Catalog.creditsTitle, [:]))
		.task {
			await model.loadCredits()
		}
	}

}

extension ShellModel {
	var creditsBalanceLine: String? {
		balance.map { countLine(Catalog.creditsBalance, units: $0.units) }
	}

	func creditsPackLine(_ pack: CreditPack) -> String {
		if let price = packPrices[pack.id] {
			return countLine(Catalog.creditsPackPrice, units: pack.credits.units, price: price)
		}
		return countLine(Catalog.creditsPack, units: pack.credits.units)
	}

	private func countLine(_ key: CatalogKey, units: Int, price: String? = nil) -> String {
		var vars: [String: CatalogArgument] = ["formattedCount": .integer(units)]
		if let price {
			vars["price"] = .text(price)
		}
		return displayLocale.say(key, count: units, vars)
	}
}
