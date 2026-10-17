import Foundation

public struct ReviewRef: Hashable, Sendable {
	public let chat: ChatID
	public let review: WorkoutReviewID
	public let revision: ReviewRevision
	public let delivery: UUID
}

public struct ReviewControlToken: Hashable, Sendable {
	public let ref: ReviewRef
	package let secret: UUID
}

struct Delivery: Equatable, Sendable {
	enum Presence: Equatable, Sendable {
		case shown
		case armed(UUID)
	}

	let ref: ReviewRef
	let head: ULID
	let presence: Presence

	static func fresh(for review: WorkoutReview, at head: ULID) -> Delivery {
		Delivery(
			ref: ReviewRef(
				chat: review.chat, review: review.id, revision: review.revision, delivery: UUID()),
			head: head, presence: .shown)
	}

	func acknowledge() -> Delivery {
		guard case .shown = presence else { return self }
		return Delivery(ref: ref, head: head, presence: .armed(UUID()))
	}

	func controls(_ allowed: ControlSet?) -> ReviewControls {
		guard case .armed(let secret) = presence, let allowed else { return .none }
		return .armed(allowed, ReviewControlToken(ref: ref, secret: secret))
	}

	func disarmed() -> Delivery {
		Delivery(ref: ref, head: head, presence: .shown)
	}

	func renewed() -> Delivery {
		Delivery(
			ref: ReviewRef(
				chat: ref.chat, review: ref.review, revision: ref.revision, delivery: UUID()),
			head: head, presence: .shown)
	}

	func admits(_ token: ReviewControlToken) -> Bool {
		guard case .armed(let secret) = presence else { return false }
		return token.ref == ref && token.secret == secret
	}
}

public struct ReviewSnapshot: Sendable, Equatable {
	public let ref: ReviewRef
	public let state: State
	public let placement: ReviewPlacement
	public let attribution: AthleteAttribution

	public enum State: Sendable, Equatable {
		case available(ReviewContent, ReviewControls)
		case storageUnavailable(ReviewContent, DisabledReviewButtons)
		case cancelledUnknown(CancelledUnknownReview)
	}

	public var content: ReviewContent? {
		switch state {
		case .available(let content, _), .storageUnavailable(let content, _): content
		case .cancelledUnknown: nil
		}
	}

	public var cards: [ReviewCard] { content?.cards ?? [] }
	public var kept: [KeptWorkout] { content?.kept ?? [] }
	public var totals: ReviewTotals { content?.totals ?? ReviewTotals([]) }
	public var receipts: [ReviewReceipt] { content?.receipts ?? [] }
	public var authority: ReviewAuthority { content?.authority ?? .readOnly }

	public var controls: ReviewControls {
		if case .available(_, let controls) = state { return controls }
		return .none
	}

	public var notice: ReviewNotice? {
		if case .storageUnavailable = state {
			return ReviewNotice(
				kind: .storageUnavailable, key: Catalog.reviewStorageUnavailable, vars: [:])
		}
		return content?.notice
	}

	func disablingButtons() -> Self {
		switch state {
		case .available(let content, let controls):
			Self(
				ref: ref, state: .storageUnavailable(content, DisabledReviewButtons(controls)),
				placement: placement, attribution: attribution)
		case .storageUnavailable, .cancelledUnknown: self
		}
	}
}

public struct ReviewContent: Sendable, Equatable {
	public let cards: [ReviewCard]
	public let kept: [KeptWorkout]
	public let totals: ReviewTotals
	public let receipts: [ReviewReceipt]
	public let notice: ReviewNotice?
	public let authority: ReviewAuthority
}

public struct CancelledUnknownReview: Sendable, Equatable {
	public let review: WorkoutReviewID

	package init(_ body: ReviewCancelledUnknownBody) { review = body.review }
}

public enum DisabledReviewButtons: Sendable, Equatable {
	case none
	case approveOrCancel
	case retryRemainingOrCancel
	case checkAgain
	case cancelOnly

	init(_ controls: ReviewControls) {
		self =
			switch controls {
			case .none, .armed: .none
			case .approveOrCancel: .approveOrCancel
			case .retryRemainingOrCancel: .retryRemainingOrCancel
			case .checkAgain: .checkAgain
			case .cancelOnly: .cancelOnly
			}
	}
}

public enum ReviewAuthority: Sendable, Equatable {
	case readOnly
	case thisDevice
	case otherDevice
}

public enum ReviewControls: Sendable, Equatable {
	case none
	case approveOrCancel(ReviewControlToken)
	case retryRemainingOrCancel(ReviewControlToken)
	case checkAgain(ReviewRef)
	case cancelOnly(ReviewControlToken)
	case armed(ControlSet, ReviewControlToken)
}

public enum ReviewDecision: Sendable, Equatable {
	case presented(ReviewRef)
	case presentationFailed(ReviewRef)
	case showAgain(ReviewRef)
	case approve(ReviewControlToken)
	case retryRemaining(ReviewControlToken)
	case tryAgain(ReviewControlToken)
	case checkAgain(ReviewControlToken)
	case cancel(ReviewControlToken)
	case checkAgainWithoutToken(ReviewRef)
}

public enum ReviewOutcome: Sendable, Equatable {
	case completed([ReviewReceipt])
	case stopped([ReviewReceipt], ReviewNotice)
	case unconfirmed([ReviewReceipt], ReviewNotice)
	case canceled([ReviewReceipt])
	case refreshed(ReviewNotice)
	case blocked(ReviewBlock)
	case staleControl(newer: ReviewRef?)
	case wrongAction
	case presentationRecorded
	case storageUnavailable
}

public enum ReviewBlock: Sendable, Equatable {
	case turnStopping
	case trainingNotConnected
	case cannotVerify
	case accountChanged
	case pastProtected
	case coachOnly
	case workoutOnly
	case reviewedBeforeUpgrade
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
	public let progress: CardProgress

	public func lines(in display: DisplayLocale) -> [String] {
		instructions.lines(in: display)
	}
}

public struct KeptWorkout: Sendable, Equatable {
	public let name: String?
	public let date: CivilDate
	public let durationMinutes: Int?
}

public struct ReviewTotals: Sendable, Equatable {
	public let additions: Int
	public let edits: Int
	public let deletions: Int
	public let durationMinutes: Int?
}

public enum CardProgress: Sendable, Equatable {
	case remaining
	case sending
	case saved(EventID)
	case seenOnCalendar
	case noLongerOnCalendar
	case refused
	case mayHaveBeenSaved
}

public enum ReviewPlacement: Sendable, Equatable {
	case afterTurn(TurnID)
	case preparedEarlier
	case endOfConversation
}

public struct ReviewReceipt: Sendable, Equatable {
	public let index: Int
	public let progress: CardProgress
}

public struct ReviewNotice: Sendable, Equatable {
	public enum Kind: Sendable, Equatable {
		case proposedRevision, refreshedAfterStaleTarget, partialFailure, accountChanged,
			earlierVersion, storageUnavailable
	}
	public let kind: Kind
	public let key: CatalogKey
	public let vars: [String: String]
	package let differences: [TargetDifference]

	package init(
		kind: Kind, key: CatalogKey, vars: [String: String],
		differences: [TargetDifference] = []
	) {
		self.kind = kind
		self.key = key
		self.vars = vars
		self.differences = differences
	}

	package func sentences(in display: DisplayLocale) -> [String] {
		[display.say(key, vars.mapValues(CatalogArgument.text))]
			+ differences.flatMap { $0.sentences(in: display) }
	}
}
