import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test(arguments: [true, false])
	func v1PendingReviewHasNoControls(connected: Bool) async throws {
		let body = RecordBody.deviceLocal(
			.pendingProposal(
				sampleProposal(
					chatId: .main, nonce: Nonce(), expiresAt: clock.now.addingTimeInterval(300))))
		let encoded = try RecordCodec.encode(body)
		let payload = try JSONSerialization.jsonObject(with: encoded.data)
		let v1 = try JSONSerialization.data(withJSONObject: ["pendingProposal": ["_0": payload]])
		let decoded = try RecordCodec.decode(
			kind: "pendingProposal", version: 1, data: v1,
			civilDate: "1998-06-13", ulid: fixedUlid(1).rawValue
		).get()
		try await seed(
			records, [seededRecord(records, at: clock.now, ulid: fixedUlid(1), body: decoded)])
		let selectedSecrets = connected ? secrets : FakeSecretStore()
		if !connected { try selectedSecrets.storeOpenRouterKey(testKey) }
		let coach = makeCoach(
			transport: transport, intervals: ada, store: records, clock: clock,
			secrets: selectedSecrets)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		_ = await coach.decide(.presented(review.ref), in: .main)
		let presented = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(presented.authority != .thisDevice)
		#expect(presented.controls == .none)
		if let token = presented.token {
			#expect(await coach.decide(.cancel(token), in: .main) != .canceled(kept: []))
		}
		_ = await coach.decide(.showAgain(presented.ref), in: .main)
		let redisplayed = try #require(await coach.currentSnapshot(.main)?.review)
		_ = await coach.decide(.presented(redisplayed.ref), in: .main)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(
			try await records.fetch(
				RecordQuery(scope: .deviceLocal([.proposalCleared]), chatId: .main)
			).records.isEmpty)
		#expect(ada.calls.allSatisfy { !$0.isWrite })
	}
}
