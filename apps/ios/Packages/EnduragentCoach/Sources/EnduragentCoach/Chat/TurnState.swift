import Foundation

public enum TurnState: Sendable, Equatable {
	case accepted(Accepted)
	case processing(Processing)
	case completed(Completed)
	case savedWork(SavedWork)
	case failed(Failed)
	case interrupted(Interrupted)
	case unrecovered(Unrecovered)

	public var isSettled: Bool {
		switch self {
		case .completed, .savedWork, .failed, .interrupted: true
		case .accepted, .processing, .unrecovered: false
		}
	}

	public enum Accepted: Sendable, Equatable {
		case collecting(until: Date)
		case queued(position: Int)
		case awaitingRestart
		case onOtherDevice
		case beforeUpgrade
	}

	public struct Processing: Sendable, Equatable {
		public let attempt: AttemptID
		public let activity: TurnActivity
	}

	public struct Completed: Sendable, Equatable {
		public let reply: ReplyText
	}

	public struct SavedWork: Sendable, Equatable {
		public let outcome: SavedWorkOutcome
		public let saved: WriteSummary
		public let notice: AthleteNotice
	}

	public struct Failed: Sendable, Equatable {
		public let failure: CoachFailure
		public let saved: WriteSummary
		public let notice: AthleteNotice
	}

	public struct Interrupted: Sendable, Equatable {
		public let partial: String
		public let cause: InterruptionCause
		public let saved: WriteSummary
		public let notice: AthleteNotice
	}

	public struct Unrecovered: Sendable, Equatable {
		public let notice: AthleteNotice
	}
}

public enum TurnActivity: Sendable, Equatable {
	case generating(step: Int)
	case runningTools([ToolName])
	case waiting(RetryWait)
	case compacting
	case savingMemory
}

public struct RetryWait: Sendable, Equatable {
	public let until: Date
	public let reason: RetryWaitReason
}

public enum RetryWaitReason: Sendable, Equatable {
	case rateLimited
	case providerTrouble
}

public enum InterruptionCause: String, Sendable, CaseIterable {
	case athleteStopped
	case systemExpired
	case graceEnded
	case appTerminating
	case processEnded
	case stoppedBeforeStart
}

public enum ReplyText: Sendable, Equatable {
	case model(String)
	case catalog(CatalogKey)

	public func sentence(in phrasebook: CatalogPhrasebook) -> String {
		switch self {
		case .model(let text): text
		case .catalog(let key): phrasebook.say(key)
		}
	}
}
