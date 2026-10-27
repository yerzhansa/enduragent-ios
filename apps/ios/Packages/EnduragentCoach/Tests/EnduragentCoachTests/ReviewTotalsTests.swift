import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewTotalsTests {
	let today: CivilDate = "1998-09-08"
	let english = displayLocale()

	@Test func theMixedReviewTotalsItsChangesAndShowsTheKeptWorkoutUnderItsDate() async throws {
		let shown = try await committed(WorkoutReviewFixture.mixed(today: today))

		#expect(
			shown.totals
				== ReviewTotals(additions: 2, edits: 1, deletions: 1, durationMinutes: 155))
		#expect(
			shown.totals.line(in: english)
				== "2 additions, 1 edit, 1 deletion · 155 min for added or edited workouts")
		#expect(shown.content.keptDays.map { $0.heading(in: english) } == ["9/10/1998"])
		#expect(
			shown.content.keptDays.map { $0.workouts.map { $0.line(in: english) } } == [
				["Commute · 45 min"]
			])
	}

	@Test func anEditWithNoKnownDurationMakesTheMinutesUnknownAndADeleteNeverDoes() async throws {
		let unknownEdit = try await committed(
			#"{"preparation":{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09")),{"kind":"edit","eventId":401,"patch":{"name":"Long open ride"}}]}}"#,
			events: [
				PreparationFixture.workout(401, on: "1998-09-10", name: "Open ride", minutes: nil)
			])
		let unknownDelete = try await committed(
			#"{"preparation":{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09")),{"kind":"delete","eventId":402}]}}"#,
			events: [PreparationFixture.workout(402, on: "1998-09-10", name: "Spin", minutes: nil)])

		#expect(unknownEdit.cards.map(\.durationMinutes) == [25, nil])
		#expect(
			unknownEdit.totals
				== ReviewTotals(additions: 1, edits: 1, deletions: 0, durationMinutes: nil))
		#expect(
			unknownEdit.totals.line(in: english)
				== "1 addition, 1 edit, 0 deletions · total duration unknown")
		#expect(unknownDelete.cards.map(\.durationMinutes) == [25, nil])
		#expect(
			unknownDelete.totals.line(in: english)
				== "1 addition, 0 edits, 1 deletion · 25 min for added or edited workouts")
	}

	@Test func eachKindOfReviewAsksItsOwnQuestionAndNamesItsOwnApproval() async throws {
		let reviews = [
			try await committed(WorkoutReviewFixture.strengthSessions(2, today: today)),
			try await committed(WorkoutReviewFixture.editOnly),
			try await committed(WorkoutReviewFixture.deleteOnly),
			try await committed(WorkoutReviewFixture.mixed(today: today)),
		]

		#expect(
			reviews.map { $0.content.question(in: english) } == [
				"Add these workouts to your calendar?", "Update this workout on your calendar?",
				"Remove this workout from your calendar?", "Apply all reviewed changes?",
			])
		#expect(
			reviews.map { english.say($0.content.approveTitle) } == [
				"Add to calendar", "Update calendar", "Remove from calendar", "Apply changes",
			])
		#expect(
			try await committed(WorkoutReviewFixture.strengthSessions(1, today: today)).content
				.question(in: english) == "Add this workout to your calendar?")
	}

	private func committed(_ arguments: String, events: [CalendarEvent]? = nil) async throws
		-> ReviewSnapshot
	{
		let turns = ReviewTurns()
		turns.intervals.events = events ?? []
		if events == nil {
			WorkoutReviewFixture.seed(turns.intervals, today: today)
		}
		let coach = await turns.coach()
		_ = try await turns.reply(
			after: [.toolCall(name: "prepare_workout_changes", arguments: arguments)], on: coach)
		return try #require(try await coach.desk.snapshot(chat: .main))
	}
}
