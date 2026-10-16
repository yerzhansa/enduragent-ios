import Foundation

enum ReviewProjection {
	static func snapshot(
		of review: WorkoutReview, delivery: Delivery, placement: ReviewPlacement,
		attribution: AthleteAttribution
	) -> ReviewSnapshot {
		let cards = cards(of: review)
		let terminal: Bool =
			switch review.stage {
			case .completed, .canceled: true
			case .waiting, .running: false
			}
		return ReviewSnapshot(
			ref: delivery.ref,
			state: .available(
				ReviewContent(
					cards: cards, kept: review.kept, totals: totals(of: cards),
					receipts: receipts(of: cards), notice: nil,
					authority: terminal ? .readOnly : .thisDevice),
				delivery.controls(review.allowedControls)),
			placement: placement, attribution: attribution)
	}

	static func receipts(of review: WorkoutReview) -> [ReviewReceipt] {
		receipts(of: cards(of: review))
	}

	private static func receipts(of cards: [ReviewCard]) -> [ReviewReceipt] {
		cards.compactMap { card in
			switch card.progress {
			case .remaining, .sending: nil
			case .saved, .seenOnCalendar, .noLongerOnCalendar, .refused, .mayHaveBeenSaved:
				ReviewReceipt(index: card.index, progress: card.progress)
			}
		}
	}

	private static func cards(of review: WorkoutReview) -> [ReviewCard] {
		let finished = review.work.finished.map { finished in
			(finished.change, progress(of: finished.result))
		}
		let remaining = review.work.remaining.map { change in
			(change, progress(ofRemaining: change, in: review.stage))
		}
		let placed: [(ReviewChange, CardProgress)] =
			switch review.stage {
			case .running(let run): run.sending.map { [($0.change, .sending)] } ?? []
			case .waiting(.unconfirmed(let attempt)): [(attempt.change, .mayHaveBeenSaved)]
			case .canceled(let cancellation):
				cancellation.givenUp.map { ($0, .remaining) }
					+ (cancellation.unconfirmed.map { [($0.change, .mayHaveBeenSaved)] } ?? [])
			case .waiting, .completed: []
			}
		return (finished + placed + remaining)
			.sorted { $0.0.position < $1.0.position }
			.map { card(of: $0.0, progress: $0.1) }
	}

	private static func progress(of result: ChangeResult) -> CardProgress {
		switch result {
		case .saved(let receipt): .saved(receipt.event)
		case .seenOnCalendar: .seenOnCalendar
		case .noLongerOnCalendar: .noLongerOnCalendar
		}
	}

	private static func progress(ofRemaining change: ReviewChange, in stage: Stage)
		-> CardProgress
	{
		if case .waiting(.tryAgain(.refused(let refused, _))) = stage, refused == change.id {
			return .refused
		}
		return .remaining
	}

	private static func card(of change: ReviewChange, progress: CardProgress) -> ReviewCard {
		let shown = ShownWorkout(change.action)
		return ReviewCard(
			index: change.position, action: shown.action, name: shown.name, date: shown.date,
			chart: nil, instructions: ReviewInstructions(content: .supplied(shown.description)),
			durationMinutes: shown.durationSeconds.map { ($0 + 30) / 60 },
			estimatedLoad: shown.load, progress: progress)
	}

	private static func totals(of cards: [ReviewCard]) -> ReviewTotals {
		let counted = ReviewTotals(cards)
		let timed = cards.filter { card in
			if case .delete = card.action { return false }
			return true
		}
		let minutes = timed.map(\.durationMinutes)
		return ReviewTotals(
			additions: counted.additions, edits: counted.edits, deletions: counted.deletions,
			durationMinutes: minutes.contains(nil) ? nil : minutes.compactMap { $0 }.reduce(0, +))
	}
}

private struct ShownWorkout {
	let action: ReviewCard.Action
	let name: ReviewSummary
	let date: CivilDate
	let description: String
	let durationSeconds: Int?
	let load: Int?

	init(_ action: ChangeAction) {
		switch action {
		case .add(let added):
			let payload = added.payload
			self.action = .add
			name = .supplied(payload.name)
			date = payload.date
			description = payload.description
			durationSeconds = payload.movingTime
			load = payload.trainingLoad
		case .edit(let edited):
			let patch = edited.patch
			switch edited.target {
			case .reviewed(_, let reviewed):
				let desired = patch.applied(to: reviewed)
				self.action = .edit(previousName: reviewed.name)
				name = desired.name.map(ReviewSummary.supplied) ?? Self.unnamedEdit(patch)
				date = desired.date
				description = desired.description ?? ""
				durationSeconds = desired.durationSeconds
				load = desired.load
			case .upgradedWithoutSnapshot(_, let reviewedDate):
				self.action = .edit(previousName: nil)
				name = patch.name.map(ReviewSummary.supplied) ?? Self.unnamedEdit(patch)
				date = patch.date ?? reviewedDate
				description = patch.description ?? ""
				durationSeconds = patch.durationSeconds
				load = patch.trainingLoad
			}
		case .delete(let deleted):
			self.action = .delete
			switch deleted.target {
			case .reviewed(_, let reviewed):
				name = reviewed.name.map(ReviewSummary.supplied) ?? .deleteWorkout
				date = reviewed.date
				description = reviewed.description ?? ""
				durationSeconds = reviewed.durationSeconds
				load = reviewed.load
			case .upgradedWithoutSnapshot(_, let reviewedDate):
				name = .deleteWorkout
				date = reviewedDate
				description = ""
				durationSeconds = nil
				load = nil
			}
		}
	}

	private static func unnamedEdit(_ patch: WorkoutPatch) -> ReviewSummary {
		.updateWorkout(
			date: patch.date, name: patch.name, descriptionChanged: patch.description != nil)
	}
}
