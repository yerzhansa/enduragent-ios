import Foundation

public enum TurnState: Sendable, Equatable {
	case accepted(Accepted)
	case processing(Processing)
	case completed(Completed)
	case savedWork(SavedWork)
	case failed(Failed)
	case interrupted(Interrupted)

	public var retryable: Bool {
		switch self {
		case .accepted(.awaitingRestart):
			return true
		case .failed(let failed):
			switch failed.notice.action {
			case .tryAgain?:
				return true
			case .wait?, .restoreCredits?, .buyCredits?, .chooseAccessMethod?, .signInToOpenRouter?,
				nil:
				return false
			}
		case .interrupted(let interrupted):
			if case .tryAgain = interrupted.notice.action {
				return true
			}
			return false
		case .accepted, .processing, .completed, .savedWork:
			return false
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
		public let liveText: String
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
	case appTerminating
	case processEnded
	case stoppedBeforeStart
}
