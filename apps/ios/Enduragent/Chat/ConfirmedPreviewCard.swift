import EnduragentCoach
import SwiftUI

struct ConfirmedPreviewCard: View {
	var model: ShellModel
	var pending: PendingProposal

	var body: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 12) {
				Text(pending.description)
					.frame(maxWidth: .infinity, alignment: .leading)
				HStack {
					Button("Cancel") {
						model.cancelPending()
					}
					.accessibilityIdentifier("chat.preview.cancel")
					Button("Add to calendar") {
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
