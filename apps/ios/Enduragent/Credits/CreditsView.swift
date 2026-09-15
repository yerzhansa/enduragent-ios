import SwiftUI

struct CreditsView: View {
	var model: ShellModel

	var body: some View {
		List {
			if let balance = model.balance {
				Text("\(balance.units) credits")
					.accessibilityIdentifier("credits.balance")
			}
			if let catalog = model.catalog {
				ForEach(catalog.packs) { pack in
					HStack {
						if let price = model.packPrices[pack.id] {
							Text("\(pack.credits.units) credits · \(price)")
						} else {
							Text("\(pack.credits.units) credits")
						}
						Spacer()
						Button("Buy") {}
							.disabled(true)
					}
					.accessibilityIdentifier("credits.pack.\(pack.id)")
				}
			}
			Text("Testers cannot buy packs yet.")
				.accessibilityIdentifier("credits.note")
		}
		.navigationTitle("Credits")
		.task {
			await model.loadCredits()
		}
	}
}
