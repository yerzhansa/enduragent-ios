import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test func approvalDuringStopKeepsTheUnsentCardAtTheRESTBoundary() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		defer { store.release() }
		let fixture = await fixture(url: url, store: store)
		let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let stopping = Task { await fixture.coach.stop(.main) }
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					stopping.cancel()
					store.release()
				}
			) {
				await store.reached.first { _ in true } != nil
			} == true,
			"Calendar write fixture did not park within five seconds")
		#expect(await fixture.coach.decide(.approve(token), in: .main) == .blocked(.turnStopping))
		#expect(await fixture.coach.currentSnapshot(.main)?.review?.token == token)
		#expect(server.posts.isEmpty)
		store.release()
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					stopping.cancel()
					store.release()
				}
			) { await stopping.value } != nil,
			"Calendar Stop did not finish within five seconds")
		#expect(
			await fixture.coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
	}

	@Test func failedAppliedCommitCanBeRecoveredWithoutAnotherPOST() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let store = HeldAppendLog(inner: faults, holding: "reviewWrite", occurrence: 3)
		defer { store.release() }
		let fixture = await fixture(url: url, store: store)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let approving = Task { await fixture.coach.decide(.approve(token), in: .main) }
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
		#expect(outcome.notice?.key == Catalog.reviewWritePending)
		await fixture.coach.stop(.main)
		#expect(await fixture.coach.state(of: turn)?.retryable == false)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(
			await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
	}
}
