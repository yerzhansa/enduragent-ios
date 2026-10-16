import Foundation

@testable import EnduragentCoach

enum StoredCase: CaseIterable, Sendable {
	case approvalPrepared, approvalRevised, approvalRefreshed, approvalCouldNotCheck
	case approvalInterruptedBeforeWriting
	case tryAgainRefused, tryAgainNotSaved, tryAgainCouldNotCheck, tryAgainInterrupted
	case tryAgainSettled
	case unconfirmed
	case blockedTurnStopping, blockedTrainingNotConnected, blockedCannotVerify
	case blockedAccountChanged, blockedPastProtected, blockedCoachOnly, blockedWorkoutOnly
	case blockedReviewedBeforeUpgrade
	case checking, sending, completed, canceledWithUnconfirmed, canceledWithNothingUnconfirmed
	case claimedApprove, claimedTryAgain
	case refusedBadRequest, refusedUnauthorized, refusedForbidden, refusedNotFound
	case refusedRateLimited
	case add, edit, delete
	case reviewedTarget, upgradedTarget
	case saved, seenOnCalendar, noLongerOnCalendar
	case ride, weightTraining
	case differentDate, differentName, differentDuration, differentDescription, differentLoad
	case differentStructure
	case intervalsAccount, unconnectedAccount
}

func storedCases(in review: WorkoutReview) -> Set<StoredCase> {
	let changes = review.work.finished.map(\.change) + review.work.remaining + review.stage.changes
	return Set(
		[StoredCase(review.account)] + StoredCase.stage(review.stage)
			+ changes.flatMap(StoredCase.change)
			+ review.work.finished.map { StoredCase($0.result) })
}

extension StoredCase {
	fileprivate init(_ account: TrainingAccount) {
		self =
			switch account {
			case .unconnected: .unconnectedAccount
			case .intervals: .intervalsAccount
			}
	}

	fileprivate init(_ result: ChangeResult) {
		self =
			switch result {
			case .saved: .saved
			case .seenOnCalendar: .seenOnCalendar
			case .noLongerOnCalendar: .noLongerOnCalendar
			}
	}

	fileprivate static func stage(_ stage: Stage) -> [StoredCase] {
		switch stage {
		case .waiting(let waiting): waiting.storedCases
		case .running(let run):
			[run.sending == nil ? .checking : .sending, StoredCase(run.claim.action)]
		case .completed: [.completed]
		case .canceled(let cancellation):
			[
				cancellation.unconfirmed == nil
					? .canceledWithNothingUnconfirmed : .canceledWithUnconfirmed
			]
		}
	}

	fileprivate static func change(_ change: ReviewChange) -> [StoredCase] {
		switch change.action {
		case .add(let added): [.add, StoredCase(added.payload.type)]
		case .edit(let edited): [.edit, StoredCase(edited.target)]
		case .delete(let deleted): [.delete, StoredCase(deleted.target)]
		}
	}

	fileprivate init(_ action: ClaimedAction) {
		self =
			switch action {
			case .approve: .claimedApprove
			case .tryAgain: .claimedTryAgain
			}
	}

	fileprivate init(_ type: CalendarEventType) {
		self =
			switch type {
			case .ride: .ride
			case .weightTraining: .weightTraining
			}
	}

	fileprivate init(_ target: ReviewedTarget) {
		self =
			switch target {
			case .reviewed: .reviewedTarget
			case .upgradedWithoutSnapshot: .upgradedTarget
			}
	}

	fileprivate init(_ status: RefusalStatus) {
		self =
			switch status {
			case .badRequest: .refusedBadRequest
			case .unauthorized: .refusedUnauthorized
			case .forbidden: .refusedForbidden
			case .notFound: .refusedNotFound
			case .rateLimited: .refusedRateLimited
			}
	}

	fileprivate init(_ field: SnapshotField) {
		self =
			switch field {
			case .date: .differentDate
			case .name: .differentName
			case .duration: .differentDuration
			case .description: .differentDescription
			case .load: .differentLoad
			case .structure: .differentStructure
			}
	}

	fileprivate init(_ block: ReviewBlock) {
		self =
			switch block {
			case .turnStopping: .blockedTurnStopping
			case .trainingNotConnected: .blockedTrainingNotConnected
			case .cannotVerify: .blockedCannotVerify
			case .accountChanged: .blockedAccountChanged
			case .pastProtected: .blockedPastProtected
			case .coachOnly: .blockedCoachOnly
			case .workoutOnly: .blockedWorkoutOnly
			case .reviewedBeforeUpgrade: .blockedReviewedBeforeUpgrade
			}
	}
}

extension Waiting {
	fileprivate var storedCases: [StoredCase] {
		switch self {
		case .approval(let reason): reason.storedCases
		case .tryAgain(let reason): reason.storedCases
		case .unconfirmed: [.unconfirmed]
		case .blocked(let block): [StoredCase(block)]
		}
	}
}

extension ApprovalReason {
	fileprivate var storedCases: [StoredCase] {
		switch self {
		case .prepared: [.approvalPrepared]
		case .revised: [.approvalRevised]
		case .refreshed(let differences):
			[.approvalRefreshed] + differences.flatMap(\.fields).map(StoredCase.init)
		case .couldNotCheck: [.approvalCouldNotCheck]
		case .interruptedBeforeWriting: [.approvalInterruptedBeforeWriting]
		}
	}
}

extension TryAgainReason {
	fileprivate var storedCases: [StoredCase] {
		switch self {
		case .refused(_, let status): [.tryAgainRefused, StoredCase(status)]
		case .notSaved: [.tryAgainNotSaved]
		case .couldNotCheck: [.tryAgainCouldNotCheck]
		case .interrupted: [.tryAgainInterrupted]
		case .settled: [.tryAgainSettled]
		}
	}
}
