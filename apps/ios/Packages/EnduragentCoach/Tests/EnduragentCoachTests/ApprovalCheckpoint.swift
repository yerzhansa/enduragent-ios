import Foundation
import Testing

@testable import EnduragentCoach

enum ApprovalCheckpoint: CaseIterable, Sendable {
	case backoff
	case retryModelRequest

	var requests: Int { self == .backoff ? 2 : 3 }

	func reach(using clock: HeldClock) async throws {
		if self == .retryModelRequest {
			clock.release(.seconds(7))
			try await clock.waitUntilHeld(.seconds(11))
		}
	}
}

extension RetryLadderTests {
	func expectApprovalBlocked(
		at checkpoint: ApprovalCheckpoint, turn: TurnID, coach: Coach,
		model: HeldApprovalTransport, clock: HeldClock
	) async throws {
		clock.release(checkpoint == .backoff ? .seconds(7) : .seconds(11))
		if checkpoint == .retryModelRequest { try await model.waitForToolCall(in: 3) }
		let deadline = ContinuousClock.now + .seconds(1)
		repeat {
			try #require(clock.held.contains(.seconds(13)))
			let proposals = try await store.fetch(
				RecordQuery(scope: .deviceLocal([.pendingProposal]))
			).records
			let settlements = try await store.fetch(
				RecordQuery(scope: .synced([.turnSettled]))
			).records
			let state = try #require(
				await coach.currentSnapshot(.main)?.turns.first(where: { $0.id == turn })?.state)
			try #require(proposals.count == 1, "A second proposal escaped the held approval")
			try #require(settlements.isEmpty, "The turn settled before the calendar write resolved")
			try #require(!state.isSettled, "The turn settled before the calendar write resolved")
			try #require(
				transport.requests.filter { $0.charge == .chatAttempt }.count
					== checkpoint.requests,
				"The retry advanced while its calendar write was held")
			try await Task.sleep(for: .milliseconds(10))
		} while ContinuousClock.now < deadline
	}
}
