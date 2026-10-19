import Foundation

public struct ReviewOutcomeNote: Sendable, Equatable {
	package let ending: ReviewOutcomeBody.Ending
	package let lines: [OutcomeLine]

	func sentence(in display: DisplayLocale) -> String {
		switch ending {
		case .closedAtUpgrade:
			display.say(Catalog.workoutsOutcomeClosedAtUpgrade)
		case .completed, .canceled:
			lines.sorted { $0.position < $1.position }.map { line in
				line.result.sentence(naming: line.name, on: line.date, in: display)
			}.joined(separator: "\n")
		}
	}

	func closing(in display: DisplayLocale) -> String? {
		let notice: ReviewNotice? =
			switch ending {
			case .completed: .completed
			case .canceled: .canceled
			case .closedAtUpgrade: nil
			}
		return notice?.sentences(in: display).joined(separator: "\n")
	}
}

enum ReviewOutcomeNotes {
	static func notes(from records: [AthleteRecord]) -> [(
		record: AthleteRecord, body: ReviewOutcomeBody
	)] {
		var seen: Set<WorkoutReviewID> = []
		return records.sorted { $0.hlc < $1.hlc }.compactMap { record in
			guard case .synced(.reviewOutcome(let body)) = record.body,
				seen.insert(body.review).inserted
			else { return nil }
			return (record, body)
		}
	}
}

extension Conversation {
	mutating func placeOutcomeNotes() {
		for index in segments.indices {
			segments[index].notes.removeAll {
				if case .outcome = $0.content { return true }
				return false
			}
		}
		for (record, body) in ReviewOutcomeNotes.notes(from: Array(outcomeRecords.values)) {
			let index = segmentIndex(for: record.ulid, at: record.hlc)
			let after = body.after.flatMap { turn in
				segments[index].turns.contains { $0.turn == turn } ? turn : nil
			}
			segments[index].notes.append(
				ReviewNote(
					ulid: record.ulid, hlc: record.hlc, date: record.civilDate,
					account: record.account,
					content: .outcome(ReviewOutcomeNote(ending: body.ending, lines: body.lines)),
					after: after))
			segments[index].notes.sort { $0.hlc < $1.hlc }
		}
	}
}

extension OutcomeLine.Result {
	func sentence(naming name: String, on date: CivilDate, in display: DisplayLocale) -> String {
		display.say(
			key,
			[
				"workout": .text(name.isEmpty ? display.say(Catalog.coachProposalUnnamed) : name),
				"date": .day(date),
			])
	}

	private var key: CatalogKey {
		switch self {
		case .saved: Catalog.workoutsOutcomeSaved
		case .seenOnCalendar: Catalog.workoutsOutcomeSeenOnCalendar
		case .noLongerOnCalendar: Catalog.workoutsOutcomeNoLongerOnCalendar
		case .givenUp: Catalog.workoutsOutcomeGivenUp
		case .mayHaveBeenSaved: Catalog.workoutsOutcomeMayHaveBeenSaved
		}
	}
}
