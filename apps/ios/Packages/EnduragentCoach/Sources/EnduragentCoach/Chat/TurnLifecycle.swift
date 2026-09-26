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
	case processEnded
	case stoppedBeforeStart
}

package enum TurnEvent: Sendable, Equatable {
	case accept(Draft, joining: TurnID?, slash: SlashCommand?)
	case claim(AttemptID)
	case observeReply(AttemptID)
	case settle(AttemptID, Settlement)
	case stopBeforeStart(AttemptID)
}

package enum TurnWrites: Sendable, Equatable {
	case nothing
	case synced([SyncedRecordBody])
	case local([DeviceLocalRecordBody])
}

package enum TurnRefusal: Error, Sendable, Equatable {
	case unknownTurn
	case acceptedElsewhere
	case alreadyAnswered
	case attemptInFlight
	case rateLimitWaitRunning
}

package enum TurnLifecycle {
	package static func writes(
		for event: TurnEvent,
		on facts: TurnFacts?,
		chat: ChatID,
		device: DeviceID,
		mint: () -> TurnID
	) -> Result<TurnWrites, TurnRefusal> {
		switch event {
		case .accept(let draft, let joining, let slash):
			if let facts, facts.fragments.contains(where: { $0.draft == draft.id }) {
				return .success(.nothing)
			}
			let turn: TurnID
			let fragment: Int
			if let joining, let facts, facts.turn == joining {
				turn = joining
				fragment = facts.fragments.count
			} else {
				turn = mint()
				fragment = 0
			}
			return .success(
				.synced([
					.userMessage(
						UserMessageBody(
							chatId: chat,
							turn: turn,
							fragment: fragment,
							draft: draft.id,
							athleteText: draft.text,
							slash: slash
						)
					)
				]))
		case .claim(let attempt):
			guard let facts else { return .failure(.unknownTurn) }
			if let refusal = claimRefusal(of: facts, device: device) {
				return .failure(refusal)
			}
			return .success(
				.local([.turnClaim(TurnClaimBody(chatId: chat, turn: facts.turn, attempt: attempt))]
				)
			)
		case .observeReply(let attempt):
			guard let facts else { return .failure(.unknownTurn) }
			if facts.replyObserved.contains(where: { $0.attempt == attempt }) {
				return .success(.nothing)
			}
			return .success(
				.local([
					.replyObserved(
						ReplyObservedBody(chatId: chat, turn: facts.turn, attempt: attempt))
				]))
		case .settle(let attempt, let settlement):
			guard let facts else { return .failure(.unknownTurn) }
			if facts.settlements.contains(where: { $0.attempt == attempt }) {
				return .success(.nothing)
			}
			return .success(
				.synced([
					.turnSettled(
						TurnSettledBody(
							chatId: chat, turn: facts.turn, attempt: attempt, settlement: settlement
						))
				]))
		case .stopBeforeStart(let attempt):
			guard let facts else { return .failure(.unknownTurn) }
			guard facts.openClaims.isEmpty else { return .failure(.attemptInFlight) }
			return .success(
				.synced([
					.turnSettled(
						TurnSettledBody(
							chatId: chat,
							turn: facts.turn,
							attempt: attempt,
							settlement: .interrupted(
								partial: "", cause: .stoppedBeforeStart, saved: .none)
						))
				]))
		}
	}

	package static func claimRefusal(of facts: TurnFacts, device: DeviceID) -> TurnRefusal? {
		if facts.origin != device {
			return .acceptedElsewhere
		}
		if facts.legacy {
			return .alreadyAnswered
		}
		return replayRefusal(after: facts.latestSettlement?.settlement)
	}

	package static func retryRefusal(of facts: TurnFacts?, overlay: TurnOverlay, device: DeviceID)
		-> TurnRefusal?
	{
		guard let facts else { return .unknownTurn }
		switch overlay {
		case .collecting, .queued: return .attemptInFlight
		case .waitingToTryAgain: return .rateLimitWaitRunning
		case .notInThisProcess: return claimRefusal(of: facts, device: device)
		}
	}

	package static func replayRefusal(after settlement: Settlement?) -> TurnRefusal? {
		switch settlement {
		case .replied?, .savedWork?:
			return .alreadyAnswered
		case .failed(_, let saved)?, .interrupted(_, _, let saved)?:
			return saved.isEmpty ? nil : .alreadyAnswered
		case nil:
			return nil
		}
	}

	package static func state(
		of facts: TurnFacts,
		live: LiveAttempt?,
		overlay: TurnOverlay,
		device: DeviceID
	) -> TurnState {
		if let live, live.turn == facts.turn,
			!facts.settlements.contains(where: { $0.attempt == live.attempt })
		{
			return .processing(
				TurnState.Processing(
					attempt: live.attempt, liveText: live.text, activity: live.activity))
		}
		switch overlay {
		case .collecting(let until):
			return .accepted(.collecting(until: until))
		case .queued(let position):
			return .accepted(.queued(position: position))
		case .waitingToTryAgain, .notInThisProcess:
			break
		}
		if let latest = facts.latestSettlement {
			let retry = replayRefusal(after: latest.settlement) == nil ? facts.turn : nil
			switch latest.settlement {
			case .replied(let reply, _):
				return .completed(TurnState.Completed(reply: reply))
			case .savedWork(let outcome, let saved):
				return .savedWork(
					TurnState.SavedWork(
						outcome: outcome, saved: saved, notice: AthleteNotices.notice(for: outcome))
				)
			case .failed(let failure, let saved):
				return .failed(
					TurnState.Failed(
						failure: failure,
						saved: saved,
						notice: AthleteNotices.notice(
							for: failure, turn: retry, waiting: overlay == .waitingToTryAgain)
					))
			case .interrupted(let partial, let cause, let saved):
				return .interrupted(
					TurnState.Interrupted(
						partial: partial,
						cause: cause,
						saved: saved,
						notice: AthleteNotices.notice(for: cause, saved: saved, turn: retry)
					))
			}
		}
		if facts.legacy {
			return .accepted(.beforeUpgrade)
		}
		if facts.origin != device {
			return .accepted(.onOtherDevice)
		}
		return .accepted(.awaitingRestart)
	}
}

package struct LiveAttempt: Sendable, Equatable {
	package let turn: TurnID
	package let attempt: AttemptID
	package var text: String
	package var activity: TurnActivity
}

package enum TurnOverlay: Sendable, Equatable {
	case collecting(until: Date)
	case queued(position: Int)
	case waitingToTryAgain
	case notInThisProcess

	package init(of turn: TurnID, window: OpenWindow?, queued: [TurnID], waiting: Set<TurnID>) {
		if let window, window.turn == turn {
			self = .collecting(until: window.closesAt)
		} else if let index = queued.firstIndex(of: turn) {
			self = .queued(position: index + 1)
		} else if waiting.contains(turn) {
			self = .waitingToTryAgain
		} else {
			self = .notInThisProcess
		}
	}
}

public struct CoalescingPolicy: Sendable, Equatable {
	public let window: Duration

	public init(window: Duration) {
		self.window = window
	}

	public static let npm = CoalescingPolicy(window: .milliseconds(1_500))
}

package enum MailboxWork: Sendable, Equatable {
	case turn(TurnID)
	case flush

	package var turn: TurnID? {
		guard case .turn(let turn) = self else { return nil }
		return turn
	}
}

package struct OpenWindow: Sendable, Equatable {
	package let turn: TurnID
	package let closesAt: Date
}

package struct EnvironmentResolver: Sendable {
	package let language: @Sendable () async -> LanguagePreference
	package let access: @Sendable () throws(AccessUnavailable) -> ResolvedAccess

	package init(
		language: @escaping @Sendable () async -> LanguagePreference,
		access: @escaping @Sendable () throws(AccessUnavailable) -> ResolvedAccess
	) {
		self.language = language
		self.access = access
	}
}

extension Duration {
	package var timeInterval: TimeInterval {
		TimeInterval(components.seconds)
			+ TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
	}
}
