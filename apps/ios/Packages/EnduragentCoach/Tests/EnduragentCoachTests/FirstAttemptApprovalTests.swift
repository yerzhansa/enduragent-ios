import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(.timeLimit(.minutes(1)))
	func firstAttemptApprovalKeepsReply() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let reply = "Here is a ride for tomorrow."
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [.text(reply), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			request.charge == .chatAttempt && index == 2 ? .seconds(23) : nil
		}
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(23))
		let token = try await presentReview(on: coach)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		held.release(.seconds(23))
		#expect(replyText(try #require(await settledTurn(turn, on: coach))) == reply)
		#expect(await coach.transcript(.main) == ["Add a ride", reply])
		#expect(intervals.calls.filter(\.isWrite).count == 1)
	}

	@Test(.timeLimit(.minutes(1)))
	func firstAttemptApprovalAllowsDifferentProposal() async throws {
		let held = HeldClock()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [
				.toolCall(
					name: "intervals_create_workout",
					arguments:
						#"{"date":"1998-06-16","workout":{"name":"Tempo","steps":[{"type":"steady","duration":{"value":45,"unit":"minutes"},"power":{"kind":"percent_ftp","low":76,"high":87}}]}}"#
				),
				.finish(reason: .toolCalls), .text("Tuesday is next."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let model = HeldApprovalTransport(base: transport, clock: held) { index, request in
			request.charge == .chatAttempt && index == 2 ? .seconds(29) : nil
		}
		let coach = heldApprovalCoach(held, model: model, intervals: intervals)
		let turn = try #require(
			try await coach.send(draft("Add two rides"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(29))
		let token = try await presentReview(on: coach)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		held.release(.seconds(29))
		#expect(replyText(try #require(await settledTurn(turn, on: coach))) == "Tuesday is next.")
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(review.cards.first?.date == "1998-06-16")
		let second = try await presentReview(on: coach)
		#expect(
			await coach.decide(.approve(second), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(intervals.calls.filter(\.isWrite).count == 2)
	}
}
