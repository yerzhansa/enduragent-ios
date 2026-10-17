import EnduragentCoach
import SwiftUI

struct ConfirmedPreviewCard: View {
	var model: ShellModel
	var review: ReviewSnapshot
	var round: Int

	var body: some View {
		if review.cards.isEmpty {
			ReviewTranscriptRow(model: model, review: review, card: nil, leads: true, ends: true)
		} else {
			ForEach(rows, id: \.id) { row in
				ReviewTranscriptRow(
					model: model, review: review, card: row.card,
					leads: row.card.index == review.cards.first?.index,
					ends: row.card.index == review.cards.last?.index)
			}
		}
	}

	static func topRow(of review: ReviewSnapshot, round: Int) -> String {
		ShownCard.id(of: review.ref, round: round, index: review.cards.first?.index)
	}

	private var rows: [ShownCard] {
		review.cards.map { ShownCard(card: $0, ref: review.ref, round: round) }
	}
}

private struct ShownCard {
	let card: ReviewCard
	let ref: ReviewRef
	let round: Int

	var id: String { Self.id(of: ref, round: round, index: card.index) }

	static func id(of ref: ReviewRef, round: Int, index: Int?) -> String {
		[
			"review", ref.review.ulid.rawValue, String(ref.revision.rawValue), String(round),
			index.map(String.init) ?? "none",
		].joined(separator: ".")
	}
}

private struct ReviewTranscriptRow: View {
	var model: ShellModel
	var review: ReviewSnapshot
	var card: ReviewCard?
	var leads: Bool
	var ends: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if leads {
				Text(model.phrasebook.say(Catalog.reviewTitle, [:]))
					.font(.headline)
					.accessibilityIdentifier("chat.preview.title")
				if review.placement == .preparedEarlier {
					Text(model.phrasebook.say(Catalog.workoutsPreparedEarlier, [:]))
						.foregroundStyle(.secondary)
						.accessibilityIdentifier("chat.preview.preparedEarlier")
				}
			}
			if let card {
				ReviewCardView(model: model, card: card, count: review.cards.count)
					.onAppear {
						Task { await model.cardAppeared(card) }
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
