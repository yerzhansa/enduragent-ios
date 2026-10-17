import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewCommitTests {
	let turns = ReviewTurns()

	@Test func aPreparedTurnCommitsRevisionOneOnlyWhenItsReplyEnds() async throws {
		let coach = await turns.coach()
		let read = turns.intervals.hold(.activities)
		turns.script([
			turns.prepare(ReviewTurns.fourChanges), .finish(reason: .toolCalls),
			.toolCall(name: "get_pending_workout_changes", arguments: "{}"),
			.toolCall(name: "intervals_fetch_activities", arguments: #"{"oldest":"1998-09-01"}"#),
			.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop),
		])
		let turn = try #require(try await coach.send(draft("Plan my week"), to: .main).acceptedTurn)
		try #require(
			try await beforeDeadline(within: .hangGuard) { await read.waitUntilEntered() } != nil)

		#expect(try await coach.desk.snapshot(chat: .main) == nil)
		#expect(try await coach.desk.pending(chat: .main) == .none)
		#expect(try await turns.head(of: coach).1 == nil)

		await read.release()
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == "Ready.")
		#expect(try turns.toolData()[1] == .object(["kind": .string("none")]))
		let review = try #require(try await turns.head(of: coach).1)
		#expect(review.revision == ReviewRevision(rawValue: 1))
		#expect(review.origin.turn == turn)
		#expect(review.stage == .waiting(.approval(.prepared)))
		#expect(review.work.finished.isEmpty)
		#expect(review.work.remaining.map(\.position) == [0, 1, 2, 3])
		#expect(
			try await turns.store.fetch(RecordQuery(scope: .deviceLocal([.workoutReview])))
				.records.count == 1)
		let card = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(card.cards.count == 4)
		#expect(card.ref.revision == ReviewRevision(rawValue: 1))
		#expect(card.controls == .none)
		#expect(try await turns.settled(turn).map(\.reviewNotPrepared) == [nil])
		#expect(try await turns.view(of: turn, on: coach).reviewNotice == nil)
	}

	@Test func aWaitingReviewHasNoTimerAndOutlivesAnUnrelatedTurn() async throws {
		let coach = await turns.coach()
		let committed = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		let (head, _) = try await turns.head(of: coach)
		turns.clock.advance(by: 11 * 60)
		turns.script([
			.toolCall(name: "get_pending_workout_changes", arguments: "{}"),
			.finish(reason: .toolCalls), .text("Ride easy today."), .finish(reason: .stop),
		])

		let unrelated = try #require(
			try await coach.send(draft("How was my ride?"), to: .main).acceptedTurn)

		#expect(
			replyText(try #require(await coach.settledState(of: unrelated, in: .main)))
				== "Ride easy today.")
		let pending = try #require(try turns.toolData().first).objectFields
		#expect(pending["kind"] == .string("pending"))
		#expect(
			pending["reference"]
				== .object([
					"setId": .string(committed.id.ulid.rawValue), "revision": .number(1),
				]))
		#expect(pending["changes"]?.arrayValue?.count == 4)
		let after = try await turns.head(of: coach)
		#expect(after.0 == head)
		#expect(after.1 == committed)
		#expect(try await turns.view(of: unrelated, on: coach).reviewNotice == nil)
	}
}
