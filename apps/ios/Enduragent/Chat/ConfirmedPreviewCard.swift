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
						card.lines(in: model.displayLocale).isEmpty
							? card.name.sentence(in: model.displayLocale)
							: card.lines(in: model.displayLocale).joined(separator: "\n")
					)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				if let notice = review.notice {
					Text(model.phrasebook.say(notice.key, notice.vars))
						.accessibilityIdentifier("chat.preview.notice")
				}
				if !actions.isEmpty || !disabledButtons.isEmpty {
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
			guard case .available = review.state else { return }
			await model.decide(
				presentable ? .presented(review.ref) : .presentationFailed(review.ref))
		}
	}

	var actions: [ConfirmedPreviewAction] {
		if case .storageUnavailable = review.state {
			return [ConfirmedPreviewAction(button: .retryRead, decision: .checkAgain(review.ref))]
		}
		guard review.authority == .thisDevice else { return [] }
		return switch review.controls {
		case .approveOrCancel(let token):
			[
				ConfirmedPreviewAction(button: .cancel, decision: .cancel(token)),
				ConfirmedPreviewAction(button: .add, decision: .approve(token)),
			]
		case .checkAgain(let ref):
			[ConfirmedPreviewAction(button: .checkAgain, decision: .checkAgain(ref))]
		case .retryRemainingOrCancel(let token):
			[
				ConfirmedPreviewAction(button: .checkAgain, decision: .checkAgain(token.ref)),
				ConfirmedPreviewAction(button: .cancel, decision: .cancel(token)),
				ConfirmedPreviewAction(button: .saveAgain, decision: .retryRemaining(token)),
			]
		case .cancelOnly(let token):
			[ConfirmedPreviewAction(button: .cancel, decision: .cancel(token))]
		case .none: []
		}
	}

	var disabledButtons: [ConfirmedPreviewButton] {
		guard case .storageUnavailable(_, let layout) = review.state else { return [] }
		return switch layout {
		case .none: []
		case .approveOrCancel: [.cancel, .add]
		case .retryRemainingOrCancel: [.checkAgain, .cancel, .saveAgain]
		case .checkAgain: [.checkAgain]
		case .cancelOnly: [.cancel]
		}
	}

	@ViewBuilder
	private var buttons: some View {
		ForEach(actions, id: \.id) { action in
			Button(say(action.title)) {
				Task { await model.decide(action.decision) }
			}
			.accessibilityIdentifier(action.id)
		}
		ForEach(disabledButtons, id: \.rawValue) { button in
			Button(say(button.title)) {}
				.accessibilityIdentifier(button.rawValue)
				.disabled(true)
		}
	}

	private var presentable: Bool {
		!review.cards.isEmpty
			&& review.cards.allSatisfy {
				!$0.lines(in: model.displayLocale).isEmpty
					|| !$0.name.sentence(in: model.displayLocale).isEmpty
			}
	}

	private func say(_ key: CatalogKey) -> String {
		model.phrasebook.say(key, [:])
	}
}

enum ConfirmedPreviewButton: String {
	case cancel = "chat.preview.cancel"
	case add = "chat.preview.add"
	case checkAgain = "chat.preview.checkAgain"
	case saveAgain = "chat.preview.saveAgain"
	case retryRead = "chat.preview.retryRead"

	var title: CatalogKey {
		switch self {
		case .cancel: Catalog.commonCancel
		case .add: Catalog.reviewAdd
		case .checkAgain: Catalog.setupTelegramCheckAgain
		case .saveAgain: Catalog.reviewSaveApprovedAgain
		case .retryRead: Catalog.reviewRetryRead
		}
	}
}

struct ConfirmedPreviewAction {
	let button: ConfirmedPreviewButton
	let decision: ReviewDecision
	var id: String { button.rawValue }
	var title: CatalogKey { button.title }
}
