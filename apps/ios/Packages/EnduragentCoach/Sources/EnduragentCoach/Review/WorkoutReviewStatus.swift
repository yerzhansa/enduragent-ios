import Foundation

package enum WorkoutReviewStatus: Equatable, Sendable {
	case read(PendingReview, newestEnding: ReviewOutcomeBody?)
	case unreadable
}

extension WorkoutReviewDesk {
	package func status(
		chat: ChatID, for account: TrainingAccount, using ownership: InformationOwnership
	) async -> WorkoutReviewStatus {
		do throws(LedgerFailure) {
			return .read(
				try await pending(chat: chat),
				newestEnding: try await ledger.newestReviewOutcome(
					chat: chat, visibleIn: ownership.scope(for: account, device: ledger.deviceId),
					using: ownership))
		} catch {
			diagnostics.record(.reviewUnavailable(chat, error))
			return .unreadable
		}
	}
}
