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
}
