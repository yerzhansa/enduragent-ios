import EnduragentCoach
import SwiftUI

struct ConfirmedPreviewCard: View {
	var model: ShellModel
	var pending: PendingProposal

	var body: some View {
		GroupBox("Confirmed preview") {
			VStack(alignment: .leading, spacing: 12) {
				Text(pending.description)
					.frame(maxWidth: .infinity, alignment: .leading)
				HStack {
					Button(model.builder.phrasebook.say(Catalog.commonCancel, [:])) {
						model.cancelPending()
					}
					.accessibilityIdentifier("chat.preview.cancel")
					Button(model.builder.phrasebook.say(Catalog.chatAddToCalendar, [:])) {
						Task { await model.confirmPending() }
					}
					.accessibilityIdentifier("chat.preview.add")
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.accessibilityElement(children: .contain)
	}
}
