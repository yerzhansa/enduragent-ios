import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewProjectionScaleTests {
	let turns = ReviewTurns()
	let today: CivilDate = "1998-09-08"
	let english = displayLocale()

	struct LongReview: Sendable, CustomTestStringConvertible {
		let days: [Int]
		let durations: [Int]
		let totals: String
		let arguments: @Sendable (CivilDate) -> String

		var testDescription: String { "\(days.count) changes" }

		static let eight = LongReview(
			days: WorkoutReviewFixture.eightWorkoutDays,
			durations: [50, 30, 50, 30, 50, 30, 50, 30],
			totals: "8 additions, 0 edits, 0 deletions · 320 min for added or edited workouts",
			arguments: WorkoutReviewFixture.eightWorkouts(today:))
		static let twenty = sessions(20, totals: "600 min")
		static let forty = sessions(40, totals: "1,200 min")

		static func sessions(_ count: Int, totals minutes: String) -> LongReview {
			LongReview(
				days: Array(1...count), durations: Array(repeating: 30, count: count),
				totals:
					"\(count) additions, 0 edits, 0 deletions · \(minutes) for added or edited workouts",
				arguments: { WorkoutReviewFixture.strengthSessions(count, today: $0) })
		}
	}

	@Test(arguments: [LongReview.eight, .twenty, .forty])
	func aLongReviewShowsEveryCardEveryKeptWorkoutAndTheTotalsAndRunsOnOneApproval(
		_ long: LongReview
	) async throws {
		let (coach, calendar) = await seededCoach()
		let shown = try await committed(long.arguments(today), on: coach)
		let count = long.days.count

		#expect(shown.cards.map(\.index) == Array(0..<count))
		#expect(
			shown.cards.map { $0.heading(of: count, in: english) }
				== zip(long.days, long.durations).enumerated().map { index, change in
					let date = english.date(today.adding(days: change.0), style: .numeric)
					return "Add · \(index + 1) of \(count) · \(date) · \(change.1) min"
				})
		#expect(shown.cards.allSatisfy { !$0.title(in: english).isEmpty })
		#expect(
			shown.content.keptDays.map { $0.heading(in: english) } == [
				"9/10/1998", "9/11/1998", "9/12/1998",
			])
		#expect(
			shown.content.keptDays.flatMap { $0.workouts.map { $0.line(in: english) } } == [
				"Commute · 45 min", "Endurance · 60 min", "Recovery spin · 30 min",
			])
		#expect(
			shown.totals
				== ReviewTotals(
					additions: count, edits: 0, deletions: 0,
					durationMinutes: long.durations.reduce(0, +)))
		#expect(shown.totals.line(in: english) == long.totals)
		#expect(shown.content.question(in: english) == "Add these workouts to your calendar?")

		var presentation = ReviewPresentation(of: shown)
		let decisions = shown.cards.map { presentation.appeared($0, of: shown, in: english) }
		#expect(decisions.dropLast().allSatisfy { $0 == nil })
		#expect(decisions.last == .presented(shown.ref))
		#expect(await coach.decide(.presented(shown.ref), in: .main) == .presentationRecorded)
		let armed = try #require(try await coach.desk.snapshot(chat: .main))
		guard case .armed(.approveOrCancel, let token) = armed.controls else {
			Issue.record("every card appeared, yet the review offers \(armed.controls)")
			return
		}

		guard case .completed = await coach.decide(.approve(token), in: .main) else {
			Issue.record("one approval did not run the whole review of \(count) changes")
			return
		}
		let added = calendar.writes.compactMap { write -> String? in
			guard case .create(let payload, let identity) = write else { return nil }
			return payload.requestBody(identity).objectFields["start_date_local"]?.stringValue
		}
		#expect(added == long.days.map { "\(today.adding(days: $0).rawValue)T00:00:00" })
	}

	@Test func nothingCapsTheNumberOfChangesInAReview() async throws {
		let count = 200
		let (coach, calendar) = await seededCoach()
		let shown = try await committed(
			WorkoutReviewFixture.strengthSessions(count, today: today), on: coach)

		#expect(shown.cards.count == count)
		#expect(
			shown.cards.last?.heading(of: count, in: english).hasPrefix("Add · 200 of 200") == true)
		#expect(shown.totals.additions == count)
		var presentation = ReviewPresentation(of: shown)
		let decisions = shown.cards.compactMap { presentation.appeared($0, of: shown, in: english) }
		#expect(decisions == [.presented(shown.ref)])
		_ = await coach.decide(.presented(shown.ref), in: .main)
		let armed = try #require(try await coach.desk.snapshot(chat: .main))
		guard case .armed(.approveOrCancel, let token) = armed.controls else {
			Issue.record("the review of \(count) changes offers \(armed.controls)")
			return
		}
		guard case .completed = await coach.decide(.approve(token), in: .main) else {
			Issue.record("the review of \(count) changes did not complete")
			return
		}
		#expect(calendar.writes.count == count)
	}

	private func seededCoach() async -> (Coach, ScriptedCalendar) {
		turns.intervals.events = []
		WorkoutReviewFixture.seed(turns.intervals, today: today)
		let calendar = ScriptedCalendar(turns.intervals)
		let coach = await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store,
			clock: turns.clock)
		return (coach, calendar)
	}

	private func committed(_ arguments: String, on coach: Coach) async throws -> ReviewSnapshot {
		_ = try await turns.reply(
			after: [.toolCall(name: "prepare_workout_changes", arguments: arguments)], on: coach)
		return try #require(try await coach.desk.snapshot(chat: .main))
	}
}
