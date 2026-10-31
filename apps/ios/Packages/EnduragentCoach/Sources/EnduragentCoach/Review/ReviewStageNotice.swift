import Foundation

extension ReviewProjection {
	static func notice(of review: WorkoutReview) -> ReviewNotice? {
		switch review.stage {
		case .running: .sending
		case .completed: .completed
		case .canceled: .canceled
		case .waiting(.approval(.prepared)), .waiting(.approval(.revised)): nil
		case .waiting(.approval(.refreshed(let differences))):
			refreshedNotice(of: review, naming: differences)
		case .waiting(.approval(let reason)): ReviewNotice.waiting(for: reason)
		case .waiting(.tryAgain(let reason)): ReviewNotice.tryingAgain(after: reason)
		case .waiting(.unconfirmed): .unconfirmed
		case .waiting(.blocked(let block)): ReviewNotice.blocked(block)
		}
	}
}

extension ReviewNotice {
	private static let service = ["service": "intervals.icu"]

	static let stopped = ReviewNotice(
		kind: .partialFailure, key: Catalog.workoutsStopped, vars: [:])
	static let couldNotCheck = ReviewNotice(
		kind: .partialFailure, key: Catalog.reviewCannotVerify, vars: service)
	static let refused = ReviewNotice(
		kind: .partialFailure, key: Catalog.workoutsPartial, vars: service)
	static let unconfirmed = ReviewNotice(
		kind: .partialFailure, key: Catalog.workoutsUnconfirmed, vars: service)
	static let sending = ReviewNotice(kind: .progress, key: Catalog.workoutsSending, vars: service)
	static let completed = ReviewNotice(kind: .outcome, key: Catalog.workoutsCompleted, vars: [:])
	static let canceled = ReviewNotice(kind: .outcome, key: Catalog.workoutsCanceled, vars: [:])

	static func waiting(for reason: ApprovalReason) -> ReviewNotice {
		switch reason {
		case .couldNotCheck: couldNotCheck
		case .prepared, .revised, .refreshed, .interruptedBeforeWriting: stopped
		}
	}

	static func tryingAgain(after reason: TryAgainReason) -> ReviewNotice {
		switch reason {
		case .refused: refused
		case .couldNotCheck: couldNotCheck
		case .notSaved, .interrupted, .settled: stopped
		}
	}

	static func blocked(_ block: ReviewBlock) -> ReviewNotice {
		switch block {
		case .accountChanged:
			ReviewNotice(kind: .accountChanged, key: Catalog.reviewAccountChanged, vars: service)
		case .trainingNotConnected:
			ReviewNotice(kind: .blocked, key: Catalog.connectMissing, vars: [:])
		case .cannotVerify:
			ReviewNotice(kind: .blocked, key: Catalog.workoutsBlockedMissing, vars: service)
		case .pastProtected:
			ReviewNotice(kind: .blocked, key: Catalog.workoutsBlockedPastProtected, vars: [:])
		case .coachOnly:
			ReviewNotice(kind: .blocked, key: Catalog.workoutsBlockedCoachOnly, vars: [:])
		case .workoutOnly:
			ReviewNotice(kind: .blocked, key: Catalog.workoutsBlockedWorkoutOnly, vars: [:])
		case .reviewedBeforeUpgrade:
			ReviewNotice(
				kind: .blocked, key: Catalog.workoutsBlockedReviewedBeforeUpgrade, vars: [:])
		}
	}
}
