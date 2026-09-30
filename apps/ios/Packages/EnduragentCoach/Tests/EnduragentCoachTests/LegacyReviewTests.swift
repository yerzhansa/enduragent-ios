import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test(
		arguments: [true, false],
		[
			(
				GatedToolName.intervalsCreateStrengthWorkout,
				GatedToolInput.createStrengthWorkout(
					date: "1998-06-13", name: "Core", description: "20 min")
			),
			(
				.intervalsUpdateWorkout,
				.updateWorkout(UpdateWorkoutInput(eventId: EventID(rawValue: 42), name: "Recovery"))
			),
			(.intervalsDeleteWorkout, .deleteWorkout(eventId: EventID(rawValue: 42))),
		])
	func v1PendingReviewHasNoControls(
		connected: Bool, action: (GatedToolName, GatedToolInput)
	) async throws {
		var proposal = sampleProposal(
			chatId: .main, nonce: Nonce(), expiresAt: clock.now.addingTimeInterval(300))
		proposal.tool = action.0
		proposal.toolInput = action.1
		let body = RecordBody.deviceLocal(.pendingProposal(proposal))
		let encoded = try RecordCodec.encode(body)
		let payload = try JSONSerialization.jsonObject(with: encoded.data)
		let v1 = try JSONSerialization.data(withJSONObject: ["pendingProposal": ["_0": payload]])
		let decoded = try RecordCodec.decode(
			kind: "pendingProposal", version: 1, data: v1,
			civilDate: "1998-06-13", ulid: fixedUlid(1).rawValue
		).get()
		try await seed(
			records, [seededRecord(records, at: clock.now, ulid: fixedUlid(1), body: decoded)])
		let selectedSecrets =
			connected ? secrets : ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		if !connected {
			try selectedSecrets.storeCreditsAccount(
				CreditsAccount(
					appAccountToken: UUID(), key: testKey)
			)
		}
		let coach = makeCoach(
			transport: transport, intervals: ada, store: records, clock: clock,
			secrets: selectedSecrets)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		_ = await coach.decide(.presented(review.ref), in: .main)
		let presented = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(presented.authority == .readOnly)
		#expect(presented.controls == .none)
		let notice = try #require(presented.notice)
		#expect(notice.key.rawValue == "review.earlierVersion")
		#expect(
			phrasebook.say(notice.key, notice.vars)
				== "This workout review is from an earlier version of the app and can no longer be applied."
		)
		if let token = presented.token {
			#expect(await coach.decide(.cancel(token), in: .main) != .canceled(kept: []))
		}
		_ = await coach.decide(.showAgain(presented.ref), in: .main)
		let redisplayed = try #require(await coach.currentSnapshot(.main)?.review)
		_ = await coach.decide(.presented(redisplayed.ref), in: .main)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.currentSnapshot(.main)?.review?.notice == notice)
		#expect(
			try await records.fetch(
				RecordQuery(scope: .deviceLocal([.proposalCleared]), chatId: .main)
			).records.isEmpty)
		#expect(ada.calls.allSatisfy { !$0.isWrite })
	}
}
