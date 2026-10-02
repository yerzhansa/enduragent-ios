import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test func cancellationAtTheDispatchBoundaryReloadsAsUnknown() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let inner = InMemoryRecordLog()
		let store = HeldAppendLog(inner: inner, holding: "reviewWrite", occurrence: 2)
		defer { store.release() }
		let fixture = await fixture(url: url, store: store)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let approving = Task { await fixture.coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approving.cancel()
					store.release()
				}
			) {
				await store.reached.first { _ in true } != nil
			} == true,
			"Calendar write fixture did not park within five seconds")
		#expect(server.posts.isEmpty)
		approving.cancel()
		store.release()
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approving.cancel()
					store.release()
				}
			) { await approving.value } != nil,
			"Calendar approval did not finish within five seconds")
		await fixture.coach.stop(.main)
		#expect(server.posts.isEmpty)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: inner)
		#expect(turnNotice(of: try #require(await reopened.state(of: turn)))?.action == nil)
		let pending = try #require(await reopened.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		_ = await reopened.decide(.checkAgain(pending.ref), in: .main)
		let checked = try #require(await reopened.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let retry) = checked.controls else {
			Issue.record("expected the captured approval to remain recoverable")
			return
		}
		_ = await reopened.decide(.retryRemaining(retry), in: .main)
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
		#expect(await reopened.currentSnapshot(.main)?.review == nil)
	}

	@Test func aFailedUnknownCommitSendsNothingAndKeepsTheCard() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let store = HeldAppendLog(inner: faults, holding: "reviewWrite", occurrence: 2)
		defer { store.release() }
		let fixture = await fixture(url: url, store: store)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let approving = Task { await fixture.coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approving.cancel()
					store.release()
				}
			) {
				await store.reached.first { _ in true } != nil
			} == true,
			"Calendar write fixture did not park within five seconds")
		faults.failNextAppend = true
		store.release()
		let outcome = try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approving.cancel()
					store.release()
				}
			) { await approving.value },
			"Calendar approval did not finish within five seconds")
		#expect(outcome == .storageUnavailable)
		#expect(server.posts.isEmpty)
		#expect(await fixture.coach.currentSnapshot(.main)?.review?.token == token)
		await fixture.coach.stop(.main)
		fixture.model.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						#"{"date":"1998-06-14","name":"Revised strength","description":"Four sets"}"#
				),
				.finish(reason: .toolCalls), .text("Revised."), .finish(reason: .stop),
			], for: .chat, otherwise: fixture.model.respond)
		try await fixture.coach.retry(turn, in: .main)
		_ = try #require(await fixture.coach.settledState(of: turn, in: .main))
		let revised = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.presented(revised.ref), in: .main)
		let revisedToken = try #require(await fixture.coach.currentSnapshot(.main)?.review?.token)
		server.state.withLock { $0.response = .status(500) }
		_ = await fixture.coach.decide(.approve(revisedToken), in: .main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(
			await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
		#expect(server.posts.count == 1)
		#expect(server.events.first?["name"]?.stringValue == "Revised strength")
	}
}
