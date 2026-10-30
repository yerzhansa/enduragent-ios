package enum ClaimedAction: String, Equatable, Sendable {
	case approve
	case tryAgain
}

package struct Claim: Equatable, Sendable {
	package let id: ClaimID
	package let action: ClaimedAction
}

package struct TargetDifference: Equatable, Sendable {
	package let change: ChangeID
	package let before: WorkoutSnapshot
	package let after: WorkoutSnapshot

	package var fields: Set<SnapshotField> { before.differences(from: after) }
}

package enum RefusalStatus: Int, Equatable, Sendable {
	case badRequest = 400
	case unauthorized = 401
	case forbidden = 403
	case notFound = 404
	case rateLimited = 429
}

package enum ApprovalReason: Equatable, Sendable {
	case prepared
	case revised
	case refreshed([TargetDifference])
	case couldNotCheck
	case interruptedBeforeWriting
}

package enum TryAgainReason: Equatable, Sendable {
	case refused(ChangeID, RefusalStatus)
	case notSaved(ChangeID)
	case couldNotCheck
	case interrupted
	case settled
}

extension Waiting {
	package var controls: ControlSet {
		switch self {
		case .approval: .approveOrCancel
		case .tryAgain: .tryAgainOrCancel
		case .unconfirmed: .checkAgainOrCancel
		case .blocked: .cancelOnly
		}
	}
}

package enum TransitionRefusal: Error, Equatable, Sendable {
	case wrongStage
	case wrongAction
}
