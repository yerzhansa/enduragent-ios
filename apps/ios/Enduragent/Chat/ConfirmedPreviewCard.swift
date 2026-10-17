import EnduragentCoach
import SwiftUI

struct ConfirmedPreviewCard: View {
	var model: ShellModel
	var review: ReviewSnapshot

	var body: some View {
		GroupBox(say(Catalog.reviewTitle)) {
			VStack(alignment: .leading, spacing: 12) {
				if review.placement == .preparedEarlier {
					Text(say(Catalog.workoutsPreparedEarlier))
						.foregroundStyle(.secondary)
						.accessibilityIdentifier("chat.preview.preparedEarlier")
				}
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
				if let outcome = model.reviewNotice {
					ReviewOutcomeNotice(model: model, notice: outcome)
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
		guard case .armed(let set, let token) = review.controls else { return [] }
		return ConfirmedPreviewButton.layout(of: set).map { button in
			ConfirmedPreviewAction(button: button, decision: button.decision(token))
		}
	}

	var disabledButtons: [ConfirmedPreviewButton] {
		guard case .storageUnavailable(_, let disabled?) = review.state else { return [] }
		return ConfirmedPreviewButton.layout(of: disabled)
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

struct ReviewOutcomeNotice: View {
	var model: ShellModel
	var notice: AthleteNotice

	var body: some View {
		Text(notice.sentence(in: model.displayLocale))
			.accessibilityIdentifier("chat.review.notice")
		ForEach(Array(notice.actions.enumerated()), id: \.offset) { _, action in
			Button(model.phrasebook.say(action.title)) {
				Task { await model.perform(action) }
			}
			.accessibilityIdentifier("chat.review.connect")
		}
	}
}

enum ConfirmedPreviewButton: String {
	case cancel = "chat.preview.cancel"
	case add = "chat.preview.add"
	case tryAgain = "chat.preview.tryAgain"
	case checkAgain = "chat.preview.checkAgain"

	static func layout(of set: ControlSet) -> [Self] {
		switch set {
		case .approveOrCancel: [.cancel, .add]
		case .tryAgainOrCancel: [.tryAgain, .cancel]
		case .checkAgainOrCancel: [.checkAgain, .cancel]
		case .cancelOnly: [.cancel]
		}
	}

	var title: CatalogKey {
		switch self {
		case .cancel: Catalog.commonCancel
		case .add: Catalog.reviewAdd
		case .tryAgain: Catalog.chatTranscriptRetry
		case .checkAgain: Catalog.setupTelegramCheckAgain
		}
	}

	func decision(_ token: ReviewControlToken) -> ReviewDecision {
		switch self {
		case .cancel: .cancel(token)
		case .add: .approve(token)
		case .tryAgain: .tryAgain(token)
		case .checkAgain: .checkAgain(token)
		}
	}
}

struct ConfirmedPreviewAction {
	let button: ConfirmedPreviewButton
	let decision: ReviewDecision
	var id: String { button.rawValue }
	var title: CatalogKey { button.title }
}
