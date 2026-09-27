import EnduragentCoach
import SwiftUI

struct ConfirmedPreviewCard: View {
	var model: ShellModel
	var review: ReviewSnapshot

	var body: some View {
		GroupBox(say(Catalog.reviewTitle)) {
			VStack(alignment: .leading, spacing: 12) {
				ForEach(review.cards, id: \.index) { card in
					Text(card.steps.isEmpty ? card.name : card.steps.joined(separator: "\n"))
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				if let notice = review.notice {
					Text(model.builder.phrasebook.say(notice.key, notice.vars))
						.accessibilityIdentifier("chat.preview.notice")
				}
				if review.notice?.kind != .accountChanged {
					HStack {
						Button(say(Catalog.commonCancel)) {
							decide(ReviewDecision.cancel)
						}
						.accessibilityIdentifier("chat.preview.cancel")
						Button(say(Catalog.reviewAdd)) {
							decide(ReviewDecision.approve)
						}
						.accessibilityIdentifier("chat.preview.add")
					}
					.disabled(token == nil)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.accessibilityElement(children: .contain)
		.task(id: review.ref) {
			await model.decide(
				presentable ? .presented(review.ref) : .presentationFailed(review.ref))
		}
	}

	private var token: ReviewControlToken? {
		guard case .approveOrCancel(let token) = review.controls else { return nil }
		return token
	}

	private var presentable: Bool {
		!review.cards.isEmpty
			&& review.cards.allSatisfy { !$0.steps.isEmpty || !$0.name.isEmpty }
	}

	private func decide(_ intent: @escaping (ReviewControlToken) -> ReviewDecision) {
		guard let token else { return }
		Task { await model.decide(intent(token)) }
	}

	private func say(_ key: CatalogKey) -> String {
		model.builder.phrasebook.say(key, [:])
	}
}
