import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewDuringReplyTests {
	let turns = ReviewTurns()

	@Test func aReviewCommittedBeforeItsTurnIsSavedStaysHiddenUntilTheTurnSettles()
		async throws
	{
		let held = HeldAppendLog(inner: turns.store, holding: "turnSettled", occurrence: 1)
		let coach = await turns.coach(over: held)
		await coach.lifecycle(.becameActive)
		turns.script([
			turns.prepare(ReviewTurns.oneRide), .finish(reason: .toolCalls), .text("Ready."),
			.finish(reason: .stop),
		])
		let turn = try #require(try await coach.send(draft("Plan my week"), to: .main).acceptedTurn)
		try await held.waitUntilReached()

		let committed = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(committed.placement == .afterTurn(turn))
		#expect(try await coach.mailbox(for: .main).reviewChanged() == .presentationRecorded)
		let replying = try #require(await coach.currentSnapshot(.main))
		#expect(replying.turns.first?.state.isSettled == false)
		#expect(replying.review == nil)

		held.release()
		let settled = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				$0.turns.first?.state.isSettled == true && $0.review != nil
			})
		#expect(settled.review?.ref == committed.ref)
	}

	@Test func theFirstSnapshotOfASettledTurnCarriesTheRevisionItCommitted() async throws {
		let notes = RecordQuery(
			scope: .synced(
				[.reviewOutcome],
				includeLegacy: [.reviewApplied, .reviewWrite, .reviewCancelledUnknown]),
			chatId: .main)
		let observer = HeldReadLog(inner: turns.store, holding: .fetch(notes), .beforeReading)
		defer { observer.release() }
		let coach = await turns.coach(over: observer)
		await coach.lifecycle(.becameActive)
		let opened = await coach.observe(.main)
		await coach.desk.moved(.main)
		try await observer.waitUntilReached()

		async let committing = firstSnapshot(in: opened, within: .hangGuard) {
			$0.turns.first?.state.isSettled == true
		}
		turns.script([
			turns.prepare(ReviewTurns.fourChanges), .finish(reason: .toolCalls), .text("Ready."),
			.finish(reason: .stop),
		])
		let first = try #require(
			try await coach.send(draft("Plan my week"), to: .main).acceptedTurn)
		let committed = try #require(try await committing)
		let original = try #require(try await turns.head(of: coach).1)
		#expect(committed.turns.map(\.id) == [first])
		#expect(committed.review?.ref.review == original.id)
		#expect(committed.review?.ref.revision == ReviewRevision(rawValue: 1))

		let edit = try #require(original.work.remaining.dropFirst(2).first)
		let continued = await coach.observe(.main)
		async let revising = firstSnapshot(in: continued, within: .hangGuard) {
			$0.turns.count == 2 && $0.turns.last?.state.isSettled == true
		}
		turns.script([
			turns.prepare(
				turns.revise(
					original,
					[(edit.reference, #"{"kind":"edit","eventId":201,"patch":{"name":"Tempo"}}"#)])),
			.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop),
		])
		let second = try #require(
			try await coach.send(draft("Make Thursday easier"), to: .main).acceptedTurn)
		let revised = try #require(try await revising)
		#expect(revised.turns.map(\.id) == [first, second])
		#expect(revised.review?.ref.review == original.id)
		#expect(revised.review?.ref.revision == ReviewRevision(rawValue: 2))
	}
}
