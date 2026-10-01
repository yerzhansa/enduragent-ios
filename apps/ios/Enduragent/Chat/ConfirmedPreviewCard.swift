import EnduragentCoach
import SwiftUI

struct ConfirmedPreviewCard: View {
	var model: ShellModel
	var review: ReviewSnapshot

	var body: some View {
		GroupBox(say(Catalog.reviewTitle)) {
			VStack(alignment: .leading, spacing: 12) {
				ForEach(review.cards, id: \.index) { card in
					Text(
						card.lines(in: model.phrasebook).isEmpty
							? card.name.sentence(in: model.phrasebook)
							: card.lines(in: model.phrasebook).joined(separator: "\n")
					)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				if let notice = review.notice {
					Text(model.phrasebook.say(notice.key, notice.vars))
						.accessibilityIdentifier("chat.preview.notice")
				}
				if !actions.isEmpty {
					ViewThatFits(in: .horizontal) {
						HStack { buttons }
						VStack(alignment: .leading) { buttons }
					}
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

	var actions: [ConfirmedPreviewAction] {
		guard review.authority == .thisDevice, review.notice?.kind != .accountChanged else {
			return []
		}
		return switch review.controls {
		case .approveOrCancel(let token):
			[
				ConfirmedPreviewAction(
					id: "chat.preview.cancel", title: Catalog.commonCancel, decision: .cancel(token)
				),
				ConfirmedPreviewAction(
					id: "chat.preview.add", title: Catalog.reviewAdd, decision: .approve(token)),
			]
		case .none, .checkAgain, .retryRemainingOrCancel: []
		}
	}

	private var buttons: some View {
		ForEach(actions, id: \.id) { action in
			Button(say(action.title)) {
				Task { await model.decide(action.decision) }
			}
			.accessibilityIdentifier(action.id)
		}
	}

	private var presentable: Bool {
		!review.cards.isEmpty
			&& review.cards.allSatisfy {
				!$0.lines(in: model.phrasebook).isEmpty
					|| !$0.name.sentence(in: model.phrasebook).isEmpty
			}
	}

	private func say(_ key: CatalogKey) -> String {
		model.phrasebook.say(key, [:])
	}
}

struct ConfirmedPreviewAction {
	let id: String
	let title: CatalogKey
	let decision: ReviewDecision
}
