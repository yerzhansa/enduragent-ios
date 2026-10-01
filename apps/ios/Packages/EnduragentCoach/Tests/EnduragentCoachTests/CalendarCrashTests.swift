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
		try await waitUntil { store.isHeld }
		#expect(server.posts.isEmpty)
		approving.cancel()
		store.release()
		_ = await approving.value
		await fixture.coach.stop(.main)
		#expect(server.posts.isEmpty)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: inner)
		#expect(await reopened.state(of: turn)?.retryable == false)
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
		let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let approving = Task { await fixture.coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await waitUntil { store.isHeld }
		faults.failNextAppend = true
		store.release()
		#expect(await approving.value == .storageUnavailable)
		#expect(server.posts.isEmpty)
		#expect(await fixture.coach.currentSnapshot(.main)?.review?.token == token)
		await fixture.coach.stop(.main)
	}
}
