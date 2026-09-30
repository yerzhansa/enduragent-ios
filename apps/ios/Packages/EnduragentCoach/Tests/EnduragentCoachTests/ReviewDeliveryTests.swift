import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func staleSnapshotCannotUnlockNewerApproval() async throws {
		let staleRead = ReviewGate()
		let claim = ReviewGate()
		let log = GatedReviewLog(inner: records, gate: claim, readGate: staleRead)
		let coach = gatedCoach(log: log, client: ada)
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
		#expect(await coach.decide(.presented(token.ref), in: .main) == .presentationRecorded)
		let redisplayed = try #require(await coach.currentSnapshot(.main)?.review)
		_ = await coach.decide(.presented(redisplayed.ref), in: .main)
		let refreshed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(refreshed.controls == .none)
		if let duplicate = refreshed.token {
			#expect(await coach.decide(.approve(duplicate), in: .main) == .staleControl)
		}
		await claim.release()
		_ = await approval.value
		#expect(ada.calls.filter(\.isWrite).count == 2)
	}

	@Test func earlierApprovalCannotUnlockLaterApproval() async throws {
		let firstWrite = ReviewGate()
		let secondClaim = ReviewGate()
		let log = GatedReviewLog(inner: records, gate: secondClaim)
		let client = GatedReviewIntervals(base: ada, gate: firstWrite)
		let coach = gatedCoach(log: log, client: client)
		let firstToken = try await presentedToken(on: coach)
		await firstWrite.arm()
		let first = Task { await coach.decide(.approve(firstToken), in: .main) }
		let firstHeld = await firstWrite.waitUntilEntered()
		#expect(firstHeld)
		let laterReview = try await propose(on: coach)
		#expect(laterReview.ref.set != firstToken.ref.set)
		let laterToken = try await presentedToken(on: coach)
		await secondClaim.arm()
		let later = Task { await coach.decide(.approve(laterToken), in: .main) }
		let claimHeld = await secondClaim.waitUntilEntered()
		#expect(claimHeld)
		await firstWrite.release()
		_ = await first.value
		let redisplayed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(redisplayed.ref), in: .main) == .presentationRecorded)
		let refreshed = try #require(await coach.currentSnapshot(.main)?.review)
		if let duplicateToken = refreshed.token {
			let duplicate = await coach.decide(.approve(duplicateToken), in: .main)
			#expect(duplicate == .staleControl)
		}
		await secondClaim.release()
		_ = await later.value
		#expect(ada.calls.filter(\.isWrite).count == 2)
	}

	@Test func finishingOldApprovalCannotEnableCancelDuringNewApproval() async throws {
		let firstWrite = ReviewGate()
		let secondClaim = ReviewGate()
		let log = GatedReviewLog(inner: records, gate: secondClaim)
		let client = GatedReviewIntervals(base: ada, gate: firstWrite)
		let coach = gatedCoach(log: log, client: client)
		let firstToken = try await presentedToken(on: coach)
		await firstWrite.arm()
		let first = Task { await coach.decide(.approve(firstToken), in: .main) }
		let firstHeld = await firstWrite.waitUntilEntered()
		#expect(firstHeld)
		let laterReview = try await propose(on: coach)
		#expect(laterReview.ref.set != firstToken.ref.set)
		let laterToken = try await presentedToken(on: coach)
		await secondClaim.arm()
		let later = Task { await coach.decide(.approve(laterToken), in: .main) }
		let claimHeld = await secondClaim.waitUntilEntered()
		#expect(claimHeld)
		await firstWrite.release()
		_ = await first.value
		let redisplayed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(redisplayed.ref), in: .main) == .presentationRecorded)
		let refreshed = try #require(await coach.currentSnapshot(.main)?.review)
		var acceptedCancel = false
		if let duplicateToken = refreshed.token {
			let cancellation = await coach.decide(.cancel(duplicateToken), in: .main)
			acceptedCancel = cancellation == .canceled(kept: [])
			#expect(!acceptedCancel)
		}
		await secondClaim.release()
		_ = await later.value
		#expect(ada.calls.filter(\.isWrite).count == (acceptedCancel ? 1 : 2))
	}

}
