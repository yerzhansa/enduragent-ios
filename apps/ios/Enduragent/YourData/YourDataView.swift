import EnduragentCoach
import SwiftUI

struct YourDataView: View {
	var model: ShellModel
	@State private var confirming = false

	var body: some View {
		Form {
			Section {
				Text(say(Catalog.yourDataKeeps))
					.accessibilityIdentifier("yourData.keeps")
			}
			Section {
				Button(role: .destructive) {
					confirming = true
				} label: {
					Text(say(Catalog.yourDataDeleteEverything)).frame(maxWidth: .infinity)
				}
				.accessibilityIdentifier("yourData.delete")
				if model.yourData.phase == .busy, let line = model.yourData.line {
					Text(say(line))
						.accessibilityIdentifier("yourData.outcome")
				}
			}
		}
		.navigationTitle(say(Catalog.yourDataDeleteEverything))
		.navigationBarTitleDisplayMode(.inline)
		.alert(say(Catalog.yourDataConfirmTitle), isPresented: $confirming) {
			Button(say(Catalog.yourDataDeleteEverything), role: .destructive) {
				Task { await model.deleteEverything() }
			}
			Button(say(Catalog.commonCancel), role: .cancel) {}
		} message: {
			Text(say(Catalog.yourDataConfirmBody))
		}
		.onAppear { model.yourData.forgetBusy() }
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}
