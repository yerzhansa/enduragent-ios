import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func staleRefreshKeepsTheReviewVisible() async throws {
		let staleRead = ReviewGate()
		let claim = ReviewGate()
		let log = GatedReviewLog(inner: records, gate: claim, readGate: staleRead)
		let coach = await gatedCoach(log: log, client: ada)
		let firstToken = try await presentedToken(on: coach)
		_ = await coach.decide(.approve(firstToken), in: .main)
		await staleRead.arm()
		let refresh = Task { await coach.decide(.presented(firstToken.ref), in: .main) }
		#expect(await staleRead.waitUntilEntered())
		_ = try await propose(on: coach)
		let token = try await presentedToken(on: coach)
		await claim.arm()
		let approval = Task { await coach.decide(.approve(token), in: .main) }
		#expect(await claim.waitUntilEntered())
		await staleRead.release()
		_ = await refresh.value
		let visible = await coach.currentSnapshot(.main)?.review
		#expect(visible?.ref == token.ref)
		#expect(visible?.controls == ReviewControls.none)
		await claim.release()
		_ = await approval.value
	}
}
