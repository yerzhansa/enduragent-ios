import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test func staleSnapshotCannotUnlockNewerApproval() async throws {
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

	@Test(arguments: [false, true])
	func unresolvedApprovalCannotBeReplacedOrCanceled(cancel: Bool) async throws {
		let firstWrite = ReviewGate()
		let client = GatedReviewIntervals(base: ada, gate: firstWrite)
		let coach = await gatedCoach(log: records, client: client)
		let token = try await presentedToken(on: coach)
		await firstWrite.arm()
		let approval = Task { await coach.decide(.approve(token), in: .main) }
		#expect(await firstWrite.waitUntilEntered())
		let later = try await propose(on: coach)
		#expect(later.ref.set == token.ref.set)
		#expect(later.controls == .none)
		#expect(
			await coach.decide(cancel ? .cancel(token) : .approve(token), in: .main)
				== .staleControl)
		await firstWrite.release()
		_ = await approval.value
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(ada.calls.filter(\.isWrite).count == 1)
	}
}
