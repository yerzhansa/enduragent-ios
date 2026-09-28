import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func durableClaimExistsBeforeCalendarWrite() async throws {
		let firstWrite = ReviewGate()
		let client = GatedReviewIntervals(base: ada, gate: firstWrite)
		let coach = gatedCoach(log: records, client: client)
		let token = try await presentedToken(on: coach)
		await firstWrite.arm()
		let approval = Task { await coach.decide(.approve(token), in: .main) }
		#expect(await firstWrite.waitUntilEntered())
		let clears = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.proposalCleared]), chatId: .main)
		).records
		#expect(clears.count == 1)
		await firstWrite.release()
		_ = await approval.value
	}
}
