import EnduragentCoach
import SwiftUI

struct ConfirmedPreviewCard: View {
	var model: ShellModel
	var review: ReviewSnapshot
	var round: Int
	var titleLaidOut: () -> Void
	var cardLaidOut: () -> Void

	var body: some View {
		ReviewTitleRow(model: model, review: review)
			.id(Self.titleRow(of: review))
			.onAppear(perform: titleLaidOut)
		if review.cards.isEmpty {
			ReviewTranscriptRow(model: model, review: review, card: nil, ends: true)
		} else {
			ForEach(rows, id: \.id) { row in
				ReviewTranscriptRow(
					model: model, review: review, card: row.card,
					ends: row.card.index == review.cards.last?.index
				)
				.onAppear(perform: cardLaidOut)
			}
		}
	}

	static func titleRow(of review: ReviewSnapshot) -> String {
		["review", review.ref.review.ulid.rawValue, String(review.ref.revision.rawValue), "title"]
			.joined(separator: ".")
	}

	private var rows: [ShownCard] {
		review.cards.map { ShownCard(card: $0, ref: review.ref, round: round) }
	}
}

private struct ShownCard {
	let card: ReviewCard
	let ref: ReviewRef
	let round: Int

	var id: String {
		[
			"review", ref.review.ulid.rawValue, String(ref.revision.rawValue), String(round),
			String(card.index),
		].joined(separator: ".")
	}
}

private struct ReviewTitleRow: View {
	var model: ShellModel
	var review: ReviewSnapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(model.phrasebook.say(Catalog.reviewTitle, [:]))
				.font(.headline)
				.accessibilityIdentifier("chat.preview.title")
			if review.placement == .preparedEarlier {
				Text(model.phrasebook.say(Catalog.workoutsPreparedEarlier, [:]))
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.preview.preparedEarlier")
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.accessibilityElement(children: .contain)
	}
}

private struct ReviewTranscriptRow: View {
	var model: ShellModel
	var review: ReviewSnapshot
	var card: ReviewCard?
	var ends: Bool
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@Environment(\.transcriptViewport) private var viewport
	@State private var placement = CGRect.null
	@State private var onScreen = false

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if let card {
				ReviewCardView(model: model, card: card, count: review.cards.count)
					.onGeometryChange(for: CGRect.self) {
						$0.frame(in: .global)
					} action: {
						placement = $0
					}
					.onChange(of: viewport.shows(placement), initial: true) { _, shown in
						onScreen = shown
						guard shown else { return }
						Task {
							guard onScreen else { return }
							await model.cardAppeared(card)
						}
					}
					.onDisappear {
						placement = .null
						onScreen = false
					}
			}
			if ends {
				KeptWorkoutsView(model: model, days: review.content.keptDays)
				if let notice = review.notice {
					Text(notice.sentences(in: model.displayLocale).joined(separator: "\n"))
						.accessibilityIdentifier("chat.preview.notice")
				}
				if let outcome = model.reviewNotice {
					ReviewOutcomeNotice(model: model, notice: outcome)
				}
				if ChromePlacement(dynamicTypeSize) == .inTranscript {
					ReviewBarView(model: model, review: review)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.accessibilityElement(children: .contain)
	}
}

private struct KeptWorkoutsView: View {
	var model: ShellModel
	var days: [KeptDay]

	var body: some View {
		if !days.isEmpty {
			VStack(alignment: .leading, spacing: 4) {
				Text(model.phrasebook.say(Catalog.workoutsKeptTitle, [:]))
					.font(.subheadline.weight(.semibold))
					.accessibilityIdentifier("chat.preview.kept.title")
				ForEach(days, id: \.date) { day in
					Text(day.heading(in: model.displayLocale))
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.accessibilityIdentifier("chat.preview.kept.day")
					ForEach(Array(day.workouts.enumerated()), id: \.offset) { _, workout in
						Text(workout.line(in: model.displayLocale))
							.accessibilityIdentifier("chat.preview.kept.workout")
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.accessibilityElement(children: .contain)
			.accessibilityIdentifier("chat.preview.kept")
		}
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
