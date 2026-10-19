import Foundation

enum ReviewProjection {
	static func snapshot(
		of review: WorkoutReview, delivery: Delivery, placement: ReviewPlacement,
		attribution: AthleteAttribution
	) -> ReviewSnapshot {
		let cards = cards(of: review)
		return ReviewSnapshot(
			ref: delivery.ref,
			state: .available(
				ReviewContent(
					cards: cards, kept: review.kept, totals: totals(of: cards),
					receipts: receipts(of: cards), notice: notice(of: review)),
				delivery.controls(review.allowedControls)),
			offered: review.allowedControls, placement: placement, attribution: attribution)
	}

	static func placement(of review: WorkoutReview, in conversation: Conversation)
		-> ReviewPlacement
	{
		let turn = review.origin.turn
		let earlier = conversation.segments.dropLast().contains { segment in
			segment.turns.contains { $0.turn == turn }
		}
		return earlier ? .preparedEarlier : .afterTurn(turn)
	}

	static func receipts(of review: WorkoutReview) -> [ReviewReceipt] {
		receipts(of: cards(of: review))
	}

	static func outcome(after review: WorkoutReview) -> ReviewOutcome {
		let receipts = receipts(of: review)
		switch review.stage {
		case .completed:
			return .completed(receipts)
		case .canceled:
			return .canceled(receipts)
		case .waiting(.blocked(let block)):
			return .blocked(block)
		case .waiting(.approval(.refreshed(let differences))):
			return .refreshed(refreshedNotice(of: review, naming: differences))
		case .waiting(.unconfirmed):
			return .unconfirmed(receipts, .unconfirmed)
		case .running:
			return .stopped(receipts, .stopped)
		case .waiting(.approval(let reason)):
			return .stopped(receipts, ReviewNotice.waiting(for: reason))
		case .waiting(.tryAgain(let reason)):
			return .stopped(receipts, ReviewNotice.tryingAgain(after: reason))
		}
	}

	static func summary(of review: WorkoutReview, ending: ReviewOutcomeBody.Ending)
		-> ReviewOutcomeBody
	{
		ReviewOutcomeBody(
			chatId: review.chat, review: review.id, revision: review.revision,
			after: review.origin.turn, ending: ending,
			lines: placed(review).map { change, progress in
				let shown = ShownWorkout(change.action)
				return OutcomeLine(
					position: change.position, action: shown.action, name: shown.title,
					date: shown.date, result: OutcomeLine.Result(progress))
			})
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
		placed(review).map { card(of: $0.0, progress: $0.1) }
	}

	private static func placed(_ review: WorkoutReview) -> [(ReviewChange, CardProgress)] {
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
		return (finished + placed + remaining).sorted { $0.0.position < $1.0.position }
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
			chart: shown.steps.flatMap { WorkoutChartModel($0.workout) },
			instructions: ReviewInstructions(shown.steps, otherwise: shown.description),
			durationMinutes: shown.durationSeconds.map(minutes(ofSeconds:)),
			estimatedLoad: shown.load, progress: progress, edit: shown.edit)
	}

	static func minutes(ofSeconds seconds: Int) -> Int {
		(seconds + 30) / 60
	}

	private static func totals(of cards: [ReviewCard]) -> ReviewTotals {
		var additions = 0
		var edits = 0
		var deletions = 0
		var minutes: [Int?] = []
		for card in cards {
			switch card.action {
			case .add:
				additions += 1
				minutes.append(card.durationMinutes)
			case .edit:
				edits += 1
				minutes.append(card.durationMinutes)
			case .delete:
				deletions += 1
			}
		}
		return ReviewTotals(
			additions: additions, edits: edits, deletions: deletions,
			durationMinutes: minutes.contains(nil) ? nil : minutes.compactMap { $0 }.reduce(0, +))
	}
}

private struct ShownWorkout {
	let action: ReviewCard.Action
	let name: ReviewSummary
	let date: CivilDate
	let steps: AuthoredSteps?
	let description: String
	let durationSeconds: Int?
	let load: Int?
	let edit: ReviewEdit?

	init(_ action: ChangeAction) {
		switch action {
		case .add(let added):
			let payload = added.payload
			self.action = .add
			name = .supplied(payload.name)
			date = payload.date
			steps = payload.authoredSteps
			description = payload.description
			durationSeconds = payload.movingTime
			load = payload.trainingLoad
			edit = nil
		case .edit(let edited):
			let patch = edited.patch
			steps = patch.authoredSteps
			switch edited.target {
			case .reviewed(_, let reviewed):
				let desired = patch.applied(to: reviewed)
				self.action = .edit(previousName: reviewed.name)
				name = desired.name.map(ReviewSummary.supplied) ?? Self.unnamedEdit(patch)
				date = desired.date
				description = desired.description ?? ""
				durationSeconds = desired.durationSeconds
				load = desired.load
				edit = ReviewEdit(of: patch, from: reviewed, to: desired)
			case .upgradedWithoutSnapshot(_, let reviewedDate):
				self.action = .edit(previousName: nil)
				name = patch.name.map(ReviewSummary.supplied) ?? Self.unnamedEdit(patch)
				date = patch.date ?? reviewedDate
				description = patch.description ?? ""
				durationSeconds = patch.durationSeconds
				load = patch.trainingLoad
				edit = nil
			}
		case .delete(let deleted):
			self.action = .delete
			steps = nil
			edit = nil
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

	var title: String {
		if case .supplied(let text) = name { return text }
		return ""
	}

	private static func unnamedEdit(_ patch: WorkoutPatch) -> ReviewSummary {
		.updateWorkout(
			date: patch.date, name: patch.name, descriptionChanged: patch.description != nil)
	}
}

extension ReviewEdit {
	fileprivate init(
		of patch: WorkoutPatch, from reviewed: WorkoutSnapshot, to desired: WorkoutSnapshot
	) {
		let differences = reviewed.differences(from: desired)
		let steps = patch.authoredSteps != nil || differences.contains(.structure)
		let fields: [(Field, Bool)] = [
			(.date, differences.contains(.date)), (.name, differences.contains(.name)),
			(.duration, differences.contains(.duration)), (.load, differences.contains(.load)),
			(.description, differences.contains(.description) && patch.authoredSteps == nil),
			(.steps, steps),
		]
		self.init(
			changed: fields.compactMap { $0.1 ? $0.0 : nil }, date: reviewed.date,
			name: reviewed.name,
			durationMinutes: reviewed.durationSeconds.map(ReviewProjection.minutes(ofSeconds:)),
			estimatedLoad: reviewed.load)
	}
}

extension OutcomeLine.Result {
	init(_ progress: CardProgress) {
		switch progress {
		case .saved: self = .saved
		case .seenOnCalendar: self = .seenOnCalendar
		case .noLongerOnCalendar: self = .noLongerOnCalendar
		case .remaining, .refused: self = .givenUp
		case .sending, .mayHaveBeenSaved: self = .mayHaveBeenSaved
		}
	}
}

extension ReviewInstructions {
	fileprivate init(_ authored: AuthoredSteps?, otherwise description: String) {
		self.init(content: authored.map { .cycling($0.workout) } ?? .supplied(description))
	}
}
