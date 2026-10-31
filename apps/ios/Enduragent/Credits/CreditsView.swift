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
			Button(model.phrasebook.say(Catalog.accessSwitchToOpenRouter)) {
				model.open(.accessMethod)
			}
			.accessibilityIdentifier("credits.switchToOpenRouter")
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
		balance.map {
			displayLocale.say(
				Catalog.creditsBalance, count: $0.units, ["formattedCount": .integer($0.units)])
		}
	}
}
