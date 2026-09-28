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
					Button("Cancel") {
						model.cancelPending()
					}
					.accessibilityIdentifier("chat.preview.cancel")
					Button("Add to calendar") {
						Task { await model.confirmPending() }
					}
					.accessibilityIdentifier("chat.preview.add")
					.shown(if: pending.confirmable(under: model.status))
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.accessibilityElement(children: .contain)
	}
}

extension View {
	@ViewBuilder
	fileprivate func shown(if condition: Bool) -> some View {
		if condition {
			self
		}
	}
}
