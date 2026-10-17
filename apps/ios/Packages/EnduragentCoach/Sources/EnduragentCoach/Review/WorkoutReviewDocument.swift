import Foundation

struct ReviewDocument: Codable {
	let id: String
	let revision: Int
	let chat: String
	let account: String
	let turn: String
	let attempt: String
	let finished: [FinishedDocument]
	let remaining: [ChangeDocument]
	let kept: [KeptDocument]
	let stage: StageDocument

	init(_ review: WorkoutReview) {
		id = review.id.ulid.rawValue
		revision = review.revision.rawValue
		chat = review.chat.rawValue
		account = review.account.storedValue
		turn = review.origin.turn.ulid.rawValue
		attempt = review.origin.attempt.ulid.rawValue
		finished = review.work.finished.map(FinishedDocument.init)
		remaining = review.work.remaining.map(ChangeDocument.init)
		kept = review.kept.map(KeptDocument.init)
		stage = StageDocument(review.stage)
	}
}

enum StageDocument: Codable {
	case waiting(WaitingDocument)
	case running(claim: ClaimDocument, sending: SendAttemptDocument?)
	case completed
	case canceled(givenUp: [ChangeDocument], unconfirmed: SendAttemptDocument?)

	init(_ stage: Stage) {
		self =
			switch stage {
			case .waiting(let waiting): .waiting(WaitingDocument(waiting))
			case .running(let run):
				.running(
					claim: ClaimDocument(run.claim),
					sending: run.sending.map(SendAttemptDocument.init))
			case .completed: .completed
			case .canceled(let cancellation):
				.canceled(
					givenUp: cancellation.givenUp.map(ChangeDocument.init),
					unconfirmed: cancellation.unconfirmed.map(SendAttemptDocument.init))
			}
	}
}

enum WaitingDocument: Codable {
	case approval(ApprovalDocument)
	case tryAgain(TryAgainDocument)
	case unconfirmed(SendAttemptDocument)
	case blocked(BlockDocument)

	init(_ waiting: Waiting) {
		self =
			switch waiting {
			case .approval(let reason): .approval(ApprovalDocument(reason))
			case .tryAgain(let reason): .tryAgain(TryAgainDocument(reason))
			case .unconfirmed(let attempt): .unconfirmed(SendAttemptDocument(attempt))
			case .blocked(let block): .blocked(BlockDocument(block))
			}
	}
}

struct SendAttemptDocument: Codable {
	let change: ChangeDocument
	let claim: String
	let sentAt: Double

	init(_ attempt: SendAttempt) {
		change = ChangeDocument(attempt.change)
		claim = attempt.claim.ulid.rawValue
		sentAt = attempt.sentAt.timeIntervalSince1970
	}
}

struct ClaimDocument: Codable {
	let id: String
	let action: String

	init(_ claim: Claim) {
		id = claim.id.ulid.rawValue
		action = claim.action.rawValue
	}

	func claim() throws -> Claim {
		guard let action = ClaimedAction(rawValue: action) else {
			throw RecordDecodeFailure(reason: "claim action")
		}
		return Claim(id: ClaimID(ulid: try decodeULID(id)), action: action)
	}
}

enum ApprovalDocument: Codable {
	case prepared
	case revised
	case refreshed(differences: [DifferenceDocument])
	case couldNotCheck
	case interruptedBeforeWriting

	init(_ reason: ApprovalReason) {
		self =
			switch reason {
			case .prepared: .prepared
			case .revised: .revised
			case .refreshed(let differences):
				.refreshed(differences: differences.map(DifferenceDocument.init))
			case .couldNotCheck: .couldNotCheck
			case .interruptedBeforeWriting: .interruptedBeforeWriting
			}
	}

	func reason() throws -> ApprovalReason {
		switch self {
		case .prepared: .prepared
		case .revised: .revised
		case .refreshed(let differences): .refreshed(try differences.map { try $0.difference() })
		case .couldNotCheck: .couldNotCheck
		case .interruptedBeforeWriting: .interruptedBeforeWriting
		}
	}
}

struct DifferenceDocument: Codable {
	let change: String
	let fields: [String]

	init(_ difference: TargetDifference) {
		change = difference.change.ulid.rawValue
		fields = difference.fields.map(\.rawValue).sorted()
	}

	func difference() throws -> TargetDifference {
		let parsed = fields.compactMap(SnapshotField.init(rawValue:))
		guard parsed.count == fields.count, Set(parsed).count == parsed.count else {
			throw RecordDecodeFailure(reason: "difference fields")
		}
		return TargetDifference(change: ChangeID(ulid: try decodeULID(change)), fields: Set(parsed))
	}
}

enum TryAgainDocument: Codable {
	case refused(change: String, status: Int)
	case notSaved(change: String)
	case couldNotCheck
	case interrupted
	case settled

	init(_ reason: TryAgainReason) {
		self =
			switch reason {
			case .refused(let change, let status):
				.refused(change: change.ulid.rawValue, status: status.rawValue)
			case .notSaved(let change): .notSaved(change: change.ulid.rawValue)
			case .couldNotCheck: .couldNotCheck
			case .interrupted: .interrupted
			case .settled: .settled
			}
	}

	func reason() throws -> TryAgainReason {
		switch self {
		case .refused(let change, let status):
			guard let status = RefusalStatus(rawValue: status) else {
				throw RecordDecodeFailure(reason: "refusal status")
			}
			return .refused(ChangeID(ulid: try decodeULID(change)), status)
		case .notSaved(let change): return .notSaved(ChangeID(ulid: try decodeULID(change)))
		case .couldNotCheck: return .couldNotCheck
		case .interrupted: return .interrupted
		case .settled: return .settled
		}
	}
}

enum BlockDocument: String, Codable {
	case turnStopping, trainingNotConnected, cannotVerify, accountChanged, pastProtected
	case coachOnly, workoutOnly, reviewedBeforeUpgrade

	init(_ block: ReviewBlock) {
		self =
			switch block {
			case .turnStopping: .turnStopping
			case .trainingNotConnected: .trainingNotConnected
			case .cannotVerify: .cannotVerify
			case .accountChanged: .accountChanged
			case .pastProtected: .pastProtected
			case .coachOnly: .coachOnly
			case .workoutOnly: .workoutOnly
			case .reviewedBeforeUpgrade: .reviewedBeforeUpgrade
			}
	}

	var block: ReviewBlock {
		switch self {
		case .turnStopping: .turnStopping
		case .trainingNotConnected: .trainingNotConnected
		case .cannotVerify: .cannotVerify
		case .accountChanged: .accountChanged
		case .pastProtected: .pastProtected
		case .coachOnly: .coachOnly
		case .workoutOnly: .workoutOnly
		case .reviewedBeforeUpgrade: .reviewedBeforeUpgrade
		}
	}
}

struct KeptDocument: Codable {
	let name: String?
	let date: String
	let durationMinutes: Int?

	init(_ kept: KeptWorkout) {
		name = kept.name
		date = kept.date.rawValue
		durationMinutes = kept.durationMinutes
	}

	func kept() throws -> KeptWorkout {
		KeptWorkout(name: name, date: try decodeCivilDate(date), durationMinutes: durationMinutes)
	}
}
