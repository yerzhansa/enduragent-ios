import Foundation

extension ReviewCard {
	init(_ body: ProposalBody) {
		let instructions: ReviewInstructions
		if case .createWorkout(_, let workout) = body.toolInput {
			instructions = ReviewInstructions(content: .cycling(workout))
		} else {
			instructions = ReviewInstructions(content: .supplied(body.description))
		}
		let action: Action
		let name: ReviewSummary
		let date: CivilDate?
		switch body.toolInput {
		case .createWorkout(let day, let workout):
			(action, name, date) = (.add, .supplied(workout.name), day)
		case .createStrengthWorkout(let day, let title, _):
			(action, name, date) = (.add, .supplied(title), day)
		case .updateWorkout(let update):
			(action, name, date) = (
				.edit(previousName: nil),
				update.name.map(ReviewSummary.supplied) ?? ReviewSummary(body.toolInput),
				update.date
			)
		case .deleteWorkout:
			(action, name, date) = (.delete, ReviewSummary(body.toolInput), nil)
		case .planSave:
			(action, name, date) = (.add, ReviewSummary(body.toolInput), nil)
		}
		self.init(
			index: 0, action: action, name: name, date: date, chart: nil,
			instructions: instructions,
			durationMinutes: nil, estimatedLoad: nil)
	}
}

extension ReviewTotals {
	init(_ cards: [ReviewCard]) {
		var additions = 0
		var edits = 0
		var deletions = 0
		for card in cards {
			switch card.action {
			case .add: additions += 1
			case .edit: edits += 1
			case .delete: deletions += 1
			}
		}
		self.init(additions: additions, edits: edits, deletions: deletions, durationMinutes: nil)
	}
}
