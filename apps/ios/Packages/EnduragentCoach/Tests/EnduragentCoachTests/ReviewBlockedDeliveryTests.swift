import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func blockedOlderApprovalCannotUnlockNewerApproval() async throws {
		let staleRead = ReviewGate()
		let laterClaim = ReviewGate()
		let log = GatedReviewLog(inner: records, gate: laterClaim, readGate: staleRead)
		let coach = await gatedCoach(log: log, client: ada)
		let firstToken = try await presentedToken(on: coach)
		await staleRead.arm()
		let first = Task { await coach.decide(.approve(firstToken), in: .main) }
		#expect(await staleRead.waitUntilEntered())
		secretBacking.locked = true
		await staleRead.release()
		#expect(await first.value == .blocked(.cannotVerify))
		secretBacking.locked = false
		let later = try await propose(on: coach)
		#expect(later.ref.set != firstToken.ref.set)
		let laterToken = try await presentedToken(on: coach)
		await laterClaim.arm()
		let laterApproval = Task { await coach.decide(.approve(laterToken), in: .main) }
		#expect(await laterClaim.waitUntilEntered())
		#expect(await coach.decide(.approve(firstToken), in: .main) == .staleControl)
		#expect(await coach.decide(.approve(laterToken), in: .main) == .staleControl)
		await laterClaim.release()
		_ = await laterApproval.value
		#expect(ada.calls.filter(\.isWrite).count == 1)
	}
}
