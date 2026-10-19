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
		ForEach(parts, id: \.id) { shown in
			ReviewTranscriptRow(
				model: model, review: review, part: shown.part, ends: shown.id == parts.last?.id
			)
			.onAppear(perform: cardLaidOut)
		}
	}

	static func titleRow(of review: ReviewSnapshot) -> String {
		["review", review.ref.review.ulid.rawValue, String(review.ref.revision.rawValue), "title"]
			.joined(separator: ".")
	}

	private var parts: [ShownPart] {
		let display = model.displayLocale
		let finished = review.cards.compactMap { card in
			card.finishedLine(in: display).map { FinishedChange(card: card, line: $0) }
		}
		let remaining = review.cards.filter { $0.finishedLine(in: display) == nil }
		let shown: [(part: ReviewPart, key: String)] =
			(finished.isEmpty ? [] : [(.finished(finished), "finished")])
			+ remaining.map { (.card($0), String($0.index)) }
		return (shown.isEmpty ? [(.empty, "empty")] : shown).map {
			ShownPart(part: $0.part, key: $0.key, ref: review.ref, round: round)
		}
	}
}

private struct FinishedChange: Equatable {
	let card: ReviewCard
	let line: String
}

private enum ReviewPart: Equatable {
	case finished([FinishedChange])
	case card(ReviewCard)
	case empty
}

private struct ShownPart {
	let part: ReviewPart
	let id: String

	init(part: ReviewPart, key: String, ref: ReviewRef, round: Int) {
		self.part = part
		id = [
			"review", ref.review.ulid.rawValue, String(ref.revision.rawValue), String(round), key,
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
	var part: ReviewPart
	var ends: Bool
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			switch part {
			case .finished(let changes):
				FinishedChangesView(model: model, changes: changes)
			case .card(let card):
				ReviewCardView(model: model, card: card, count: review.cards.count)
					.reportsAppearance(of: card, to: model)
			case .empty:
				EmptyView()
			}
			if ends {
				KeptWorkoutsView(model: model, days: review.content.keptDays)
				if let notice = review.notice {
					ReviewStageNotice(model: model, notice: notice)
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

private struct FinishedChangesView: View {
	var model: ShellModel
	var changes: [FinishedChange]

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(model.phrasebook.say(Catalog.workoutsFinishedTitle, [:]))
				.font(.headline)
				.accessibilityIdentifier("chat.preview.finished.title")
			ForEach(changes, id: \.card.index) { change in
				Text(change.line)
					.accessibilityIdentifier("chat.preview.finished.line")
					.reportsAppearance(of: change.card, to: model)
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("chat.preview.finished")
	}
}

private struct ReviewStageNotice: View {
	var model: ShellModel
	var notice: ReviewNotice

	var body: some View {
		let text = Text(notice.sentences(in: model.displayLocale).joined(separator: "\n"))
		switch notice.kind {
		case .storageUnavailable:
			text.accessibilityIdentifier("chat.preview.notice")
		case .outcome:
			text
				.font(.body.weight(.semibold))
				.accessibilityIdentifier("chat.preview.closing")
		case .refreshedAfterStaleTarget, .partialFailure, .accountChanged, .blocked, .progress:
			text.accessibilityIdentifier("chat.review.notice")
		}
	}
}

private struct AppearanceReport: ViewModifier {
	var model: ShellModel
	var card: ReviewCard
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
}

extension View {
	fileprivate func reportsAppearance(of card: ReviewCard, to model: ShellModel) -> some View {
		modifier(AppearanceReport(model: model, card: card))
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
		if !model.reviewNoticeRepeatsCard(notice) {
			Text(notice.sentence(in: model.displayLocale))
				.accessibilityIdentifier("chat.review.notice")
		}
		ForEach(Array(notice.actions.enumerated()), id: \.offset) { _, action in
			Button(model.phrasebook.say(action.title)) {
				Task { await model.perform(action) }
			}
			.accessibilityIdentifier("chat.review.connect")
		}
	}
}
