import Foundation

public struct KeptDay: Sendable, Equatable {
	public let date: CivilDate
	public let workouts: [KeptWorkout]

	public func heading(in display: DisplayLocale) -> String {
		display.date(date, style: .numeric)
	}
}

extension KeptWorkout {
	public func line(in display: DisplayLocale) -> String {
		display.say(
			Catalog.workoutsKeptWorkout,
			[
				"name": .text(name ?? display.say(Catalog.coachProposalUnnamed)),
				"duration": .text(
					durationMinutes.map { ReviewCard.minutes($0, in: display) }
						?? display.say(Catalog.workoutsCardDurationUnknown)),
			])
	}
}

extension ReviewTotals {
	public func line(in display: DisplayLocale) -> String {
		var parts: [String: CatalogArgument] = [
			"additions": Self.count(additions, Catalog.workoutsTotalsAdditions, in: display),
			"edits": Self.count(edits, Catalog.workoutsTotalsEdits, in: display),
			"deletions": Self.count(deletions, Catalog.workoutsTotalsDeletions, in: display),
		]
		guard let durationMinutes else {
			return display.say(Catalog.workoutsTotalsLineDurationUnknown, parts)
		}
		parts["duration"] = .text(ReviewCard.minutes(durationMinutes, in: display))
		return display.say(Catalog.workoutsTotalsLine, parts)
	}

	private static func count(_ count: Int, _ key: CatalogKey, in display: DisplayLocale)
		-> CatalogArgument
	{
		.text(display.say(key, count: count, ["count": .integer(count)]))
	}
}

extension ReviewContent {
	private enum Composition {
		case additions, edits, deletions, mixed
	}

	public var approveTitle: CatalogKey {
		switch composition {
		case .additions: Catalog.reviewAdd
		case .edits: Catalog.workoutsBarApproveEdits
		case .deletions: Catalog.workoutsBarApproveDeletions
		case .mixed: Catalog.workoutsApprove
		}
	}

	public func question(in display: DisplayLocale) -> String {
		switch composition {
		case .additions: display.say(Catalog.workoutsBarQuestionAdd, count: cards.count)
		case .edits: display.say(Catalog.workoutsBarQuestionEdit, count: cards.count)
		case .deletions: display.say(Catalog.workoutsBarQuestionDelete, count: cards.count)
		case .mixed: display.say(Catalog.workoutsBarQuestionMixed)
		}
	}

	public var keptDays: [KeptDay] {
		var dates: [CivilDate] = []
		for workout in kept where !dates.contains(workout.date) {
			dates.append(workout.date)
		}
		return dates.map { date in
			KeptDay(date: date, workouts: kept.filter { $0.date == date })
		}
	}

	private var composition: Composition {
		let actions = cards.map { card -> Composition in
			switch card.action {
			case .add: .additions
			case .edit: .edits
			case .delete: .deletions
			}
		}
		guard let first = actions.first, actions.allSatisfy({ $0 == first }) else {
			return actions.isEmpty ? .additions : .mixed
		}
		return first
	}
}
