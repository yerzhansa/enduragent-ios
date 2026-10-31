import EnduragentCoach
import SwiftUI

struct PlanCardView: View {
	var model: ShellModel
	var card: PlanCard
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize

	var body: some View {
		let text = PlanCardText(
			card, answer: model.planDecisions.answers[card.id], in: model.displayLocale)
		PlanTitleRow(text: text)
			.reportsPresentation(of: card, to: model.planDecisions)
			.id(Self.titleRow(of: card))
		PlanDetailsRow(text: text)
		if ChromePlacement(dynamicTypeSize) == .inTranscript, let token = card.armedToken {
			PlanBarView(decisions: model.planDecisions, phrasebook: model.phrasebook, token: token)
		}
	}

	static func titleRow(of card: PlanCard) -> String {
		["plan", card.id.ulid.rawValue, "title"].joined(separator: ".")
	}
}

extension PlanCard {
	var armedToken: PlanSaveToken? {
		guard case .waiting(.armed(let token)) = state else { return nil }
		return token
	}
}

struct PlanBarView: View {
	var decisions: PlanDecisions
	var phrasebook: CatalogPhrasebook
	var token: PlanSaveToken

	var body: some View {
		ViewThatFits(in: .horizontal) {
			HStack { buttons }
			VStack(alignment: .leading) { buttons }
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("chat.planSave.bar")
	}

	@ViewBuilder
	private var buttons: some View {
		ReviewBarButton(
			title: phrasebook.say(Catalog.chatPlanSaveSave, [:]), prominent: true,
			identifier: "chat.planSave.save"
		) {
			Task { await decisions.decide(.save(token)) }
		}
		.disabled(decisions.deciding)
		ReviewBarButton(
			title: phrasebook.say(Catalog.commonCancel, [:]), prominent: false,
			identifier: "chat.planSave.cancel"
		) {
			Task { await decisions.decide(.cancel(token)) }
		}
		.disabled(decisions.deciding)
	}
}

private struct PlanTitleRow: View {
	var text: PlanCardText

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(text.title)
				.font(.headline)
				.accessibilityAddTraits(.isHeader)
				.accessibilityIdentifier("chat.planSave.title")
			if let preparedEarlier = text.preparedEarlier {
				Text(preparedEarlier)
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.planSave.preparedEarlier")
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.fixedSize(horizontal: false, vertical: true)
		.accessibilityElement(children: .contain)
	}
}

private struct PlanDetailsRow: View {
	var text: PlanCardText

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(text.name)
				.font(.body.weight(.semibold))
				.accessibilityIdentifier("chat.planSave.name")
			ForEach(text.identity, id: \.id) { pair in
				PlanPairView(pair: pair)
			}
			ForEach(Array(text.phases.enumerated()), id: \.offset) { _, phase in
				VStack(alignment: .leading, spacing: 4) {
					Text(phase.title)
						.font(.subheadline.weight(.semibold))
						.accessibilityIdentifier("chat.planSave.phase")
					ForEach(phase.pairs, id: \.id) { pair in
						PlanPairView(pair: pair)
					}
				}
				.accessibilityElement(children: .contain)
			}
			if let replaces = text.replaces {
				Text(replaces)
					.accessibilityIdentifier("chat.planSave.replaces")
			}
			if let state = text.state {
				Text(state)
					.font(.body.weight(.semibold))
					.accessibilityIdentifier("chat.planSave.state")
			}
			if let answer = text.answer {
				Text(answer)
					.accessibilityIdentifier("chat.planSave.answer")
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.fixedSize(horizontal: false, vertical: true)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("chat.planSave.card")
	}
}

private struct PlanPairView: View {
	var pair: PlanCardText.Pair
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize

	var body: some View {
		if dynamicTypeSize.isAccessibilitySize {
			VStack(alignment: .leading, spacing: 2) { parts }
		} else {
			HStack(alignment: .firstTextBaseline, spacing: 8) { parts }
		}
	}

	@ViewBuilder
	private var parts: some View {
		Text(pair.label)
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("chat.planSave.\(pair.id).label")
		Text(pair.value)
			.accessibilityIdentifier("chat.planSave.\(pair.id).value")
	}
}

private struct PresentationReport: ViewModifier {
	var decisions: PlanDecisions
	var card: PlanCard
	@Environment(\.transcriptViewport) private var viewport
	@State private var placement = CGRect.null
	@State private var onScreen = false

	func body(content: Content) -> some View {
		content
			.onGeometryChange(for: CGRect.self) {
				$0.frame(in: .global)
			} action: {
				placement = $0
			}
			.onChange(of: awaitingPresentation, initial: true) { _, awaiting in
				onScreen = awaiting != nil
				guard let awaiting else { return }
				Task {
					guard onScreen else { return }
					await decisions.present(awaiting)
				}
			}
			.onDisappear {
				placement = .null
				onScreen = false
			}
	}

	private var awaitingPresentation: PlanCardRef? {
		guard card.state == .waiting(.unarmed), viewport.shows(placement) else { return nil }
		return card.ref
	}
}

extension View {
	fileprivate func reportsPresentation(of card: PlanCard, to decisions: PlanDecisions)
		-> some View
	{
		modifier(PresentationReport(decisions: decisions, card: card))
	}
}
