import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func importDoesNotRestoreAReviewCanceledWhileItReads() async throws {
		let held = HeldFlushReadLog(inner: records)
		let store = ImportingRecordLog(inner: held)
		let coach = await makeCoach(
			transport: transport, intervals: ada, store: store, clock: clock, secrets: secrets)
		let token = try await presentedToken(on: coach)
		let observed = ImportSnapshots(await coach.observe(.main))
		held.holdNextChatFlushRead()
		defer { held.release() }
		store.notifyImport()
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		#expect(await coach.decide(.cancel(token), in: .main) == .canceled(kept: []))
		try await waitUntil { observed.latest != nil && observed.latest?.review == nil }
		let count = observed.count
		held.release()
		try await waitUntil { observed.count > count }
		#expect(observed.latest?.review == nil)
	}
}
