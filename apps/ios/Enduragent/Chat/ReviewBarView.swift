import EnduragentCoach
import SwiftUI

struct ReviewBarView: View {
	var model: ShellModel
	var review: ReviewSnapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(review.totals.line(in: model.displayLocale))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.accessibilityIdentifier("chat.review.totals")
			if review.offered == .approveOrCancel {
				Text(review.content.question(in: model.displayLocale))
					.font(.headline)
					.accessibilityIdentifier("chat.review.question")
			}
			if let status = presentation?.status(of: review, in: model.displayLocale) {
				Text(status)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.review.status")
			}
			if presentation?.failure != nil {
				Button(say(Catalog.workoutsBarShowAgain)) {
					Task { await model.showReviewAgain() }
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
				.accessibilityIdentifier("chat.review.showAgain")
			}
			if !actions.isEmpty || !disabledButtons.isEmpty {
				ViewThatFits(in: .horizontal) {
					HStack { buttons }
					VStack(alignment: .leading) { buttons }
				}
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
		.padding(.horizontal, 12)
		.padding(.bottom, 8)
		.background(Color(.systemBackground))
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("chat.review.bar")
	}

	var actions: [ConfirmedPreviewAction] {
		guard case .armed(let set, let token) = review.controls else { return [] }
		return ConfirmedPreviewButton.layout(of: set).map { button in
			ConfirmedPreviewAction(
				button: button, title: button.title(in: review.content),
				decision: button.decision(token))
		}
	}

	var disabledButtons: [ConfirmedPreviewButton] {
		guard case .storageUnavailable(_, let disabled?) = review.state else { return [] }
		return ConfirmedPreviewButton.layout(of: disabled)
	}

	private var presentation: ReviewPresentation? { model.reviewPresentation }

	@ViewBuilder
	private var buttons: some View {
		ForEach(actions, id: \.id) { action in
			ReviewBarButton(
				title: say(action.title), prominent: action.button != .cancel,
				identifier: action.id
			) {
				Task { await model.decide(action.decision) }
			}
		}
		ForEach(disabledButtons, id: \.rawValue) { button in
			ReviewBarButton(
				title: say(button.title(in: review.content)), prominent: button != .cancel,
				identifier: button.rawValue
			) {}
			.disabled(true)
		}
	}

	private func say(_ key: CatalogKey) -> String {
		model.phrasebook.say(key, [:])
	}
}

private struct ReviewBarButton: View {
	var title: String
	var prominent: Bool
	var identifier: String
	var action: () -> Void

	var body: some View {
		if prominent {
			Button(title, action: action)
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				.accessibilityIdentifier(identifier)
		} else {
			Button(title, action: action)
				.buttonStyle(.bordered)
				.controlSize(.large)
				.accessibilityIdentifier(identifier)
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

	func title(in content: ReviewContent) -> CatalogKey {
		switch self {
		case .cancel: Catalog.commonCancel
		case .add: content.approveTitle
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
	let title: CatalogKey
	let decision: ReviewDecision
	var id: String { button.rawValue }
}
