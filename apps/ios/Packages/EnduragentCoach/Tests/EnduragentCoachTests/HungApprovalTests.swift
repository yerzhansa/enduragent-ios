import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(arguments: ApprovalCheckpoint.allCases)
	func hungApprovalDoesNotBlockStopOrNewSend(checkpoint: ApprovalCheckpoint) async throws {
		let held = HeldClock()
		let intervals = HeldApprovalWrites(
			base: FakeIntervalsClient(athleteName: "Ada", ftp: 250), clock: held)
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
				+ (checkpoint == .retryModelRequest ? workoutProposal : [])
				+ [.text("Rest today."), .finish(reason: .stop)], otherwise: transport.respond)
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			checkpoint == .retryModelRequest && request.charge == .chatAttempt && index == 3
				? .seconds(11) : nil
		}
		let coach = await heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		try await checkpoint.reach(using: held)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await held.waitUntilHeld(.seconds(13))
		try await expectApprovalBlocked(
			at: checkpoint, turn: turn, coach: coach, model: model, clock: held)
		let stopped = AsyncStream.makeStream(of: Bool.self)
		Task {
			await coach.stop(.main)
			stopped.continuation.yield(true)
			stopped.continuation.finish()
		}
		var stopping = stopped.stream.makeAsyncIterator()
		try #require(await stopping.next() == true)
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected interruption, got \(settled)")
			return
		}
		#expect(interrupted.saved.calendarWrites == 1)
		#expect(interrupted.saved.unverifiedCalendarWrites == 1)
		#expect(turnNotice(of: settled)?.action == nil)
		#expect(
			interrupted.notice.sentence(in: LanguageTag.en.phrasebook)
				== "The calendar change may have been saved. Check your calendar before asking again."
		)
		let sent = AsyncThrowingStream.makeStream(of: SendOutcome.self)
		Task {
			do {
				sent.continuation.yield(try await coach.send(draft("How about rest?"), to: .main))
				sent.continuation.finish()
			} catch {
				sent.continuation.finish(throwing: error)
			}
		}
		var sending = sent.stream.makeAsyncIterator()
		let next = try #require(try await sending.next()?.acceptedTurn)
		#expect(replyText(try #require(await settledTurn(next, on: coach))) == "Rest today.")
		#expect(held.held.contains(.seconds(13)))
		#expect(intervals.base.calls.filter(\.isWrite).isEmpty)
	}
}
