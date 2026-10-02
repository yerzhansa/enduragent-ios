import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test(arguments: [false, true])
	func failedConnectionCheckKeepsUnknownWriteRecoveryControls(absent: Bool) async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)
		ada.writeFailure = URLError(.timedOut)
		guard case .uncertain = await coach.decide(.approve(token), in: .main) else {
			Issue.record("expected unresolved approval")
			return
		}
		if absent { _ = await coach.decide(.checkAgain(token.ref), in: .main) }
		let pending = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(pending.controls != .none)
		let calls = ada.calls
		secretBacking.locked = true
		defer { secretBacking.locked = false }

		let outcome = await coach.decide(.checkAgain(pending.ref), in: .main)

		#expect(outcome.notice?.key == Catalog.reviewWriteReadFailed)
		let failed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(failed.notice?.key == Catalog.reviewWriteReadFailed)
		#expect(failed.controls == pending.controls)
		#expect(ada.calls == calls)
		secretBacking.locked = false
		let unlocked = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(unlocked.controls == pending.controls)
		_ = await coach.decide(.checkAgain(unlocked.ref), in: .main)
		let checked = try #require(await coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel = checked.controls else {
			Issue.record("successful check must restore approved-workout recovery")
			return
		}
		#expect(ada.calls.allSatisfy { !$0.isWrite })
	}
}

extension SingleProposalReviewsTests {
	@Test func unconnectedApprovalOffersConnectWithoutDispatch() async throws {
		try secrets.delete(.intervalsConnection)
		let coach = await coach()
		let token = try await presentedToken(on: coach)

		let outcome = await coach.decide(.approve(token), in: .main)

		#expect(outcome == .blocked(.trainingNotConnected))
		#expect(outcome.notice?.key == Catalog.connectMissing)
		#expect(outcome.notice?.action == .connectTraining)
		#expect(
			outcome.notice?.sentence(in: phrasebook)
				== "intervals.icu is not connected. Connect to add workouts to your calendar.")
		#expect(await coach.currentSnapshot(.main)?.review?.controls == .approveOrCancel(token))
		#expect(
			try await records.fetch(RecordQuery(scope: .synced([.reviewWrite]), chatId: .main))
				.records.isEmpty)
		#expect(ada.calls.isEmpty)
		#expect(bo.calls.isEmpty)
	}
}
