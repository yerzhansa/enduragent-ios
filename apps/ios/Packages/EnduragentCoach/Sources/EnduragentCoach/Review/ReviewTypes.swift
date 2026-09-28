import Foundation

public struct ReviewRef: Hashable, Sendable {
	public let chat: ChatID
	public let set: ChangeSetID
	public let revision: ChangeSetRevision
	public let delivery: UUID
}

public struct ReviewControlToken: Hashable, Sendable {
	public let ref: ReviewRef
	package let secret: UUID
}

public struct ReviewSnapshot: Sendable, Equatable {
	public let ref: ReviewRef
	public let cards: [ReviewCard]
	public let kept: [KeptWorkout]
	public let totals: ReviewTotals
	public let receipts: [ReviewReceipt]
	public let notice: ReviewNotice?
	public let controls: ReviewControls
	public let authority: ReviewAuthority
}

public enum ReviewAuthority: Sendable, Equatable {
	case thisDevice
	case otherDevice
}

public enum ReviewControls: Sendable, Equatable {
	case none
	case approveOrCancel(ReviewControlToken)
	case retryRemainingOrCancel(ReviewControlToken)
	case checkAgain(ReviewRef)
}

public enum ReviewDecision: Sendable, Equatable {
	case presented(ReviewRef)
	case presentationFailed(ReviewRef)
	case showAgain(ReviewRef)
	case approve(ReviewControlToken)
	case retryRemaining(ReviewControlToken)
	case cancel(ReviewControlToken)
	case checkAgain(ReviewRef)
}

public enum ReviewOutcome: Sendable, Equatable {
	case applied([ReviewReceipt])
	case partiallyApplied(done: [ReviewReceipt], stoppedAt: ReviewCard, failure: TrainingFailure)
	case uncertain(done: [ReviewReceipt], unresolved: ReviewCard)
	case canceled(kept: [ReviewReceipt])
	case changedSinceReview(ReviewNotice)
	case blocked(ReviewBlock)
	case staleControl
	case presentationRecorded
	case storageUnavailable
}

public enum ReviewBlock: Sendable, Equatable {
	case cannotVerify
	case accountChanged
	case pastProtected
	case coachOnly
	case workoutOnly
}

public struct WorkoutChartModel: Sendable, Equatable {
	public enum Unit: Sendable, Equatable { case percentOfFTP, watts, zone }
	public enum Segment: Sendable, Equatable {
		case steady(durationSeconds: Int, target: Double)
		case range(durationSeconds: Int, low: Double, high: Double)
		case ramp(durationSeconds: Int, start: Double, end: Double)
	}
	public let unit: Unit
	public let durationSeconds: Int
	public let segments: [Segment]
}

public struct ReviewCard: Sendable, Equatable {
	public enum Action: Sendable, Equatable {
		case add
		case edit(previousName: String?)
		case delete
	}
	public let index: Int
	public let action: Action
	public let name: ReviewSummary
	public let date: CivilDate?
	public let chart: WorkoutChartModel?
	public let instructions: ReviewInstructions
	public let durationMinutes: Int?
	public let estimatedLoad: Int?

	public func lines(in phrasebook: any Phrasebook) -> [String] {
		instructions.lines(in: phrasebook)
	}
}

public struct KeptWorkout: Sendable, Equatable {
	public let name: String
	public let date: CivilDate
	public let durationMinutes: Int?
}

public struct ReviewTotals: Sendable, Equatable {
	public let additions: Int
	public let edits: Int
	public let deletions: Int
	public let durationMinutes: Int?
}

public struct ReviewReceipt: Sendable, Equatable {
	public enum Result: Sendable, Equatable {
		case confirmed(eventId: String)
		case rejected(reason: String)
		case uncertain
	}
	public let index: Int
	public let result: Result
}

public struct ReviewNotice: Sendable, Equatable {
	public enum Kind: Sendable, Equatable {
		case proposedRevision, refreshedAfterStaleTarget, partialFailure, accountChanged
	}
	public let kind: Kind
	public let key: CatalogKey
	public let vars: [String: String]
}
