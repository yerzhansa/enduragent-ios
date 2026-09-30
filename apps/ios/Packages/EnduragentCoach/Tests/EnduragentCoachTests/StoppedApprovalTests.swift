import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test func approvalWhileStopSettlesKeepsReviewActionable() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let records = HeldAppendLog(inner: store, holding: "turnSettled", occurrence: 1)
		defer { records.release() }
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
		let coach = heldApprovalCoach(
			held, model: transport, intervals: intervals, records: records)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let stopping = Task { await coach.stop(.main) }
		var settlement = records.reached.makeAsyncIterator()
		_ = await settlement.next()
		let outcome = await coach.decide(.approve(token), in: .main)
		#expect(outcome == .blocked(.turnStopping))
		#expect(
			outcome.notice?.sentence(in: LanguageTag.en.phrasebook)
				== "This reply is stopping. You can approve or cancel the workout review once it stops."
		)
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		#expect(intervals.calls.filter(\.isWrite).isEmpty)
		records.release()
		await stopping.value
		#expect(await settledTurn(turn, on: coach)?.isSettled == true)
		let actionable = try #require(await coach.currentSnapshot(.main)?.review?.token)
		#expect(
			await coach.decide(.approve(actionable), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(intervals.calls.filter(\.isWrite).count == 1)
		#expect(await coach.currentSnapshot(.main)?.review == nil)
	}

	@Test func confirmedApprovalThenStopKeepsConfirmedNotice() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
		let coach = heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		await coach.stop(.main)
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected interruption, got \(settled)")
			return
		}
		#expect(interrupted.saved.calendarWrites == 1)
		#expect(interrupted.saved.unverifiedCalendarWrites == 0)
		#expect(
			interrupted.notice.sentence(in: LanguageTag.en.phrasebook)
				== "This reply stopped before it finished. Some information was saved first.")
		#expect(interrupted.notice.action == nil)
		#expect(!settled.retryable)
		let reopened = heldApprovalCoach(HeldClock(), model: transport, intervals: intervals)
		#expect(await reopened.currentSnapshot(.main)?.turns.first?.state == settled)
	}
}
