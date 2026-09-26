import EnduragentCoach
import SwiftUI

struct CreditsView: View {
	var model: ShellModel

	var body: some View {
		List {
			if let balance = model.balance {
				Text(countLine(Catalog.creditsBalance, units: balance.units))
					.accessibilityIdentifier("credits.balance")
			}
			if let catalog = model.catalog {
				ForEach(catalog.packs) { pack in
					HStack {
						if let price = model.packPrices[pack.id] {
							Text(
								countLine(
									Catalog.creditsPackPrice, units: pack.credits.units,
									price: price)
							)
						} else {
							Text(countLine(Catalog.creditsPack, units: pack.credits.units))
						}
						Spacer()
						Button(model.builder.phrasebook.say(Catalog.creditsBuy, [:])) {}
							.disabled(true)
					}
					.accessibilityIdentifier("credits.pack.\(pack.id)")
				}
			}
			Text(model.builder.phrasebook.say(Catalog.creditsTesters, [:]))
				.accessibilityIdentifier("credits.note")
		}
		.navigationTitle(model.builder.phrasebook.say(Catalog.creditsTitle, [:]))
		.task {
			await model.loadCredits()
		}
	}

	private func countLine(_ key: CatalogKey, units: Int, price: String? = nil) -> String {
		var vars = ["count": "\(units)", "formattedCount": "\(units)"]
		if let price {
			vars["price"] = price
		}
		return model.builder.phrasebook.say(key, vars)
	}
}
