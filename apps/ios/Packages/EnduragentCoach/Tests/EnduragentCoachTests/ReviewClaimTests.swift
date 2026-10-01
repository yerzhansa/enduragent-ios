import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func durableClaimExistsBeforeCalendarWrite() async throws {
		let firstWrite = ReviewGate()
		let client = GatedReviewIntervals(base: ada, gate: firstWrite)
		let coach = await gatedCoach(log: records, client: client)
		let token = try await presentedToken(on: coach)
		await firstWrite.arm()
		let approval = Task { await coach.decide(.approve(token), in: .main) }
		#expect(await firstWrite.waitUntilEntered())
		let writes = try await records.fetch(
			RecordQuery(scope: .synced([.reviewWrite]), chatId: .main)
		).records
		#expect(writes.count == 2)
		guard case .synced(.reviewWrite(let body)) = writes.last?.body else {
			Issue.record("expected durable evidence before dispatch")
			await firstWrite.release()
			_ = await approval.value
			return
		}
		#expect(body.evidence == .unknown(.dispatched))
		await firstWrite.release()
		_ = await approval.value
	}
}
