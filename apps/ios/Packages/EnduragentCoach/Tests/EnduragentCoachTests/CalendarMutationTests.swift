import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test(arguments: [false, true])
	func updateAndDeleteReconcileTheirCapturedEventAfterLostResponse(deleting: Bool) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let fixture = await fixture(url: url)
		let (_, initial) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(initial), in: .main)
		await fixture.coach.stop(.main)
		server.state.withLock { $0.response = .status(504) }
		fixture.model.script = [
			.toolCall(
				name: deleting ? "intervals_delete_workout" : "intervals_update_workout",
				arguments: deleting ? #"{"eventId":1}"# : #"{"eventId":1,"name":"Edited workout"}"#),
			.finish(reason: .toolCalls), .text("Review ready."), .hang,
		]
		let turn = try #require(
			try await fixture.coach.send(draft("Change the workout"), to: .main).acceptedTurn)
		await fixture.coach.waitForLiveText(turn)
		let review = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.presented(review.ref), in: .main)
		let token = try #require(await fixture.coach.currentSnapshot(.main)?.review?.token)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(
			await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(server.writes.count == 2)
		#expect(server.writes.last?.method == (deleting ? "DELETE" : "PUT"))
		#expect(server.events.count == (deleting ? 0 : 1))
		if !deleting { #expect(server.events.first?["name"]?.stringValue == "Edited workout") }
		#expect(await fixture.coach.state(of: turn)?.retryable == false)
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
	}
}
