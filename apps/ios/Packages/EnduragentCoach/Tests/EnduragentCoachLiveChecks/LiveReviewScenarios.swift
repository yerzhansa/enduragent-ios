import Foundation

@testable import EnduragentCoach

enum LivePreparationKind: String, Sendable {
	case complete
	case replace
	case revise
	case incomplete
}

enum LiveChangeShape: Sendable, Hashable, Comparable, CustomStringConvertible {
	case add(CivilDate)
	case edit(EventID)
	case delete(EventID)

	init(_ action: ChangeAction) {
		switch action {
		case .add(let add): self = .add(add.payload.date)
		case .edit(let edit): self = .edit(edit.target.event)
		case .delete(let delete): self = .delete(delete.target.event)
		}
	}

	var description: String {
		switch self {
		case .add(let date): "add on \(date.rawValue)"
		case .edit(let event): "edit of event \(event.rawValue)"
		case .delete(let event): "delete of event \(event.rawValue)"
		}
	}

	static func < (left: Self, right: Self) -> Bool {
		left.description < right.description
	}

	static func shapes(of review: WorkoutReview?) -> [LiveChangeShape] {
		(review?.work.remaining ?? []).map { Self($0.action) }.sorted()
	}
}

enum LiveReviewExpectation: Sendable, Equatable {
	case preparesNothing
	case preparesOnce(LivePreparationKind)
	case readsPendingBeforePreparing
	case holds(revision: Int, changes: [LiveChangeShape])
	case revisesOnly(LiveChangeShape)
	case replacesWith([LiveChangeShape])
	case unchanged
	case endsUnprepared([String])
	case showsNotPrepared
	case leavesNoReview
}

struct LiveSeededTarget: Sendable, Equatable {
	let key: String
	let externalID: String
	let event: EventID
	let name: String
	let date: CivilDate

	func presence(in calendar: [CalendarEvent]) -> String? {
		let rows = calendar.filter { $0.externalId == externalID }
		guard rows.map(\.id) != [event] else { return nil }
		let found = rows.map { String($0.id.rawValue) }.joined(separator: ", ")
		return
			"seeded target \(key) lists as \(found.isEmpty ? "nothing" : "event \(found)"), not once as event \(event.rawValue). Run make live-seed."
	}
}

struct LiveCancelRecord: Sendable {
	let outcome: String
	let canceled: Bool
	let calendarRequests: Int
	let waitingAfter: Bool
}

extension LiveCoachPlan {
	static let reviewTargetKeys = ["T1", "T2", "K", "coach-race"]

	static func reviews(on calendar: [CalendarEvent], today: CivilDate) -> Result<
		[LiveScenario], LiveCheckStop
	> {
		var targets: [String: LiveSeededTarget] = [:]
		var problems: [String] = []
		for entry in LiveSeedCalendar.entries where reviewTargetKeys.contains(entry.key) {
			let rows = calendar.filter { $0.externalId == entry.externalID }
			guard rows.count == 1, let event = rows.first,
				let date = CivilDate(rawValue: String(event.startDateLocal.prefix(10)))
			else {
				problems.append("\(entry.key) lists \(rows.count) times")
				continue
			}
			guard date > today else {
				problems.append("\(entry.key) is dated \(date.rawValue), not after today")
				continue
			}
			targets[entry.key] = LiveSeededTarget(
				key: entry.key, externalID: entry.externalID, event: event.id,
				name: event.name ?? entry.name, date: date)
		}
		guard problems.isEmpty, let first = targets["T1"], let second = targets["T2"],
			let race = targets["coach-race"]
		else {
			return .failure(
				LiveCheckStop(
					description:
						"workout reviews: the seeded targets are not ready (\(problems.joined(separator: "; "))). Run make live-unseed and make live-seed."
				))
		}
		let busy = Set(calendar.map { String($0.startDateLocal.prefix(10)) })
		guard
			let thursday = (1...28).map({ today.adding(days: $0) }).first(where: {
				weekday($0) == 5 && !busy.contains($0.rawValue)
			})
		else {
			return .failure(
				LiveCheckStop(
					description:
						"workout reviews: no Thursday in the next four weeks is free of calendar entries"
				))
		}
		let seeded = reviewTargetKeys.compactMap { targets[$0] }
		let saturday = thursday.adding(days: 2)
		let sunday = thursday.adding(days: 3)
		let mixed = [
			LiveChangeShape.edit(first.event), .delete(second.event), .add(thursday),
			.add(saturday),
		].sorted()
		let request = LiveTurnPlan(
			message:
				"Please make these calendar changes: change the \"\(first.name)\" on \(day(first.date)) to 75 minutes, delete the \"\(second.name)\" on \(day(second.date)), add a 60-minute endurance ride on \(day(thursday)), and add a 30-minute strength session on \(day(saturday)).",
			expectations: [
				.review(.preparesOnce(.complete)), .review(.holds(revision: 1, changes: mixed)),
			])
		return .success([
			LiveScenario(
				name: "workout-review-revise", setting: .reviewing,
				turns: [
					request,
					LiveTurnPlan(
						message: "Make Thursday easier.",
						expectations: [
							.review(.readsPendingBeforePreparing), .review(.preparesOnce(.revise)),
							.review(.revisesOnly(.add(thursday))),
							.review(.holds(revision: 2, changes: mixed)),
						]),
					LiveTurnPlan(
						message: "How much should I drink per hour on a long ride?",
						expectations: [.neverCalls(.prepareWorkoutChanges), .review(.unchanged)]),
				], targets: seeded, endsWithCancel: true),
			LiveScenario(
				name: "workout-review-replace", setting: .reviewing,
				turns: [
					request,
					LiveTurnPlan(
						message:
							"Replace all of it: I only want one 90-minute endurance ride on \(day(sunday)).",
						expectations: [
							.review(.readsPendingBeforePreparing), .review(.preparesOnce(.replace)),
							.review(.replacesWith([.add(sunday)])),
							.review(.holds(revision: 2, changes: [.add(sunday)])),
						]),
				], targets: seeded, endsWithCancel: true),
			LiveScenario(
				name: "workout-review-race", setting: .reviewing,
				turns: [
					LiveTurnPlan(
						message: "Move my \"\(race.name)\" on \(day(race.date)) to \(day(sunday)).",
						expectations: [
							.review(.endsUnprepared([raceRefusal(of: race.event), incomplete])),
							.review(.showsNotPrepared), .review(.leavesNoReview),
						])
				], targets: seeded),
		])
	}

	static func raceRefusal(of race: EventID) -> String {
		toolResult(.refused(.ineligible(race, .notAWorkout)))
	}

	static let incomplete = toolResult(.incomplete)

	private static func toolResult(_ reply: PreparationReply) -> String {
		encodeToolOutcome(.result(UntrustedEnvelope.wrap(reply.json)))
	}

	static func weekday(_ date: CivilDate) -> Int? {
		let parts = date.rawValue.split(separator: "-").compactMap { Int($0) }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone.current
		guard parts.count == 3,
			let noon = calendar.date(
				from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
		else { return nil }
		return calendar.component(.weekday, from: noon)
	}
}
