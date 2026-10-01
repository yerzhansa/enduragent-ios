import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test(arguments: [false, true])
	func failedRefreshRestoresRecoveryWithoutRepeatingTheWrite(repeatAvailable: Bool) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let fixture = await fixture(url: url, store: faults)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		if repeatAvailable {
			server.state.withLock { $0.readResponse = .body("[]") }
			_ = await fixture.coach.decide(.checkAgain(token.ref), in: .main)
		}
		let ready = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		faults.failFetches = true
		_ = await fixture.coach.decide(.presented(ready.ref), in: .main)
		let failed = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(failed.ref == ready.ref)
		#expect(failed.cards == ready.cards)
		#expect(failed.controls == .none)
		#expect(failed.notice?.key == Catalog.reviewStorageUnavailable)
		#expect(
			await fixture.coach.decide(.checkAgain(failed.ref), in: .main) == .storageUnavailable)
		#expect(await fixture.coach.currentSnapshot(.main)?.review == failed)
		#expect(server.posts.count == 1)
		faults.failFetches = false
		#expect(
			await fixture.coach.decide(.checkAgain(failed.ref), in: .main) == .presentationRecorded)
		#expect(await fixture.coach.currentSnapshot(.main)?.review == ready)
		#expect(server.posts.count == 1)
		#expect(await fixture.coach.state(of: turn)?.retryable == false)
		server.state.withLock { $0.readResponse = .success }
		#expect(
			await fixture.coach.decide(.checkAgain(ready.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
	}
}
