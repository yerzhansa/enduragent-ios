import Foundation

public struct ReviewOutcomeNote: Sendable, Equatable {
	package let lines: [OutcomeLine]

	func sentence(in display: DisplayLocale) -> String {
		lines.sorted { $0.position < $1.position }.map { line in
			display.say(
				line.result.key,
				[
					"workout": .text(
						line.name.isEmpty ? display.say(Catalog.coachProposalUnnamed) : line.name),
					"date": .day(line.date),
				])
		}.joined(separator: "\n")
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
					content: .outcome(ReviewOutcomeNote(lines: body.lines)),
					after: after))
			segments[index].notes.sort { $0.hlc < $1.hlc }
		}
	}
}

extension OutcomeLine.Result {
	fileprivate var key: CatalogKey {
		switch self {
		case .saved: Catalog.workoutsOutcomeSaved
		case .seenOnCalendar: Catalog.workoutsOutcomeSeenOnCalendar
		case .noLongerOnCalendar: Catalog.workoutsOutcomeNoLongerOnCalendar
		case .givenUp: Catalog.workoutsOutcomeGivenUp
		case .mayHaveBeenSaved: Catalog.workoutsOutcomeMayHaveBeenSaved
		}
	}
}
