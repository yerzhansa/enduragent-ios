import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func staleReadCannotResurrectFinishedReview() async throws {
		let proposal = try await propose(on: coach())
		let staleRead = ReviewGate()
		let log = GatedReviewLog(inner: records, gate: ReviewGate(), readGate: staleRead)
		let coach = await gatedCoach(log: log, client: ada)
		_ = try #require(await coach.currentSnapshot(.main)?.review)
		await staleRead.arm()
		let refresh = Task { await coach.decide(.presented(proposal.ref), in: .main) }
		#expect(await staleRead.waitUntilEntered())
		let token = try await presentedToken(on: coach)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		await staleRead.release()
		_ = await refresh.value
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(ada.calls.filter(\.isWrite).count == 1)
	}
}
