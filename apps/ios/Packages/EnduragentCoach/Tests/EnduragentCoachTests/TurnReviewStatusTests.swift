import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnReviewStatusTests {
	let turns = ReviewTurns()
	let calendar: ScriptedCalendar

	init() {
		calendar = ScriptedCalendar(turns.intervals)
	}

	@Test func theFirstTurnSeesNoWaitingAndNoEndedReview() async throws {
		let coach = await coach()

		#expect(
			try await statusSeen(by: coach) == """
				# Workout review status

				No workout review waits for the athlete.
				No workout review has ended.
				""")
	}

	@Test func theTurnAfterPreparingSeesTheWaitingReviewWithItsCount() async throws {
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.fourChanges, on: coach)

		#expect(
			try await statusSeen(by: coach) == """
				# Workout review status

				Review \(Self.named(review)) waits for the athlete to approve or cancel: 4 changes.
				No workout review has ended.
				""")
	}

	@Test func theTurnAfterApprovalSeesNothingWaitingAndTheCompletedLines() async throws {
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)
		guard case .completed = await coach.desk.decide(.approve(try await token(on: coach)))
		else {
			Issue.record("the review did not complete")
			return
		}

		#expect(
			try await statusSeen(by: coach) == """
				# Workout review status

				No workout review waits for the athlete.
				The newest ended review, \(Self.named(review)), was approved and completed:
				- add "Threshold 2x2" on 1998-09-09: saved
				""")
	}

	@Test func theTurnAfterCancelSeesNothingWaitingAndTheChangesNotMade() async throws {
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)
		guard case .canceled = await coach.desk.decide(.cancel(try await token(on: coach))) else {
			Issue.record("the review was not canceled")
			return
		}

		#expect(
			try await statusSeen(by: coach) == """
				# Workout review status

				No workout review waits for the athlete.
				The newest ended review, \(Self.named(review)), was canceled:
				- add "Threshold 2x2" on 1998-09-09: not made
				""")
	}

	@Test func aTurnDuringTheApprovedWriteSeesTheReviewRunning() async throws {
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let write = Gate()
		calendar.answer { _, _ in
			await write.wait()
			return nil
		}
		let token = try await token(on: coach)
		async let approving = coach.desk.decide(.approve(token))
		defer { write.release() }
		await write.waitUntilParked()

		let seen = try await statusSeen(by: coach)
		write.release()

		#expect(
			seen == """
				# Workout review status

				Review \(Self.named(review)) is being written to the calendar now. Nothing waits for approval.
				No workout review has ended.
				""")
		guard case .completed = await approving else {
			Issue.record("the held approval did not complete")
			return
		}
	}

	@Test func theTurnAfterALostAnswerSeesTheUnconfirmedChange() async throws {
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)
		calendar.answer { [calendar] _, _ in
			calendar.failReads()
			return .lost(.transport)
		}
		guard case .unconfirmed = await coach.desk.decide(.approve(try await token(on: coach)))
		else {
			Issue.record("the lost answer did not leave an unconfirmed change")
			return
		}

		#expect(
			try await statusSeen(by: coach) == """
				# Workout review status

				Review \(Self.named(review)) has an unconfirmed change: the athlete must check it again or cancel it.
				No workout review has ended.
				""")
	}

	@Test func anUnreadableReviewChainLeavesTheTurnRunningAndSaysTheStatusIsUnknown()
		async throws
	{
		let failing = FaultInjectingRecordLog(wrapping: turns.store)
		let coach = await makeCoach(
			transport: turns.transport, intervals: calendar, store: failing, clock: turns.clock)
		#expect(try #require(await coach.currentSnapshot(.main)).review == nil)
		failing.failNextFetch(in: .deviceLocal([.workoutReview]))

		#expect(
			try await statusSeen(by: coach) == """
				# Workout review status

				The review status could not be read this turn.
				""")
		#expect(
			coach.diagnostics.entries.contains {
				if case .reviewUnavailable(.main, _) = $0.event { true } else { false }
			})
	}

	private func coach() async -> Coach {
		await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store, clock: turns.clock)
	}

	private func statusSeen(by coach: Coach) async throws -> String {
		turns.script([.text("Nothing waits."), .finish(reason: .stop)])
		let turn = try #require(
			try await coach.send(draft("Is anything still waiting?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		let system = try #require(
			turns.transport.requests.last?.messages.first { $0.role == .system }?.content)
		let start = try #require(system.range(of: "# Workout review status"))
		let end =
			system.range(
				of: PromptAssembly.sectionSeparator, range: start.upperBound..<system.endIndex)?
			.lowerBound ?? system.endIndex
		return String(system[start.lowerBound..<end])
	}

	private func token(on coach: Coach) async throws -> ReviewControlToken {
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(_, let token) = try #require(try await coach.desk.snapshot(chat: .main))
				.controls
		else {
			throw UnexpectedReview(detail: "the review never armed its controls")
		}
		return token
	}

	private static func named(_ review: WorkoutReview) -> String {
		"setId \(review.id.ulid.rawValue), revision \(review.revision.rawValue)"
	}
}
