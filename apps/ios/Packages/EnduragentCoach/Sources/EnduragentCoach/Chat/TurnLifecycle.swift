import Foundation

package enum TurnRefusal: Error, Sendable, Equatable {
	case unknownTurn
	case acceptedElsewhere
	case alreadyAnswered
	case attemptInFlight
	case rateLimitWaitRunning
	case unrecovered
}

package enum TurnLifecycle {
	package static func accept(
		_ draft: Draft, turn: TurnID, fragment: Int, chat: ChatID, slash: SlashCommand?
	) -> UserMessageBody {
		UserMessageBody(
			chatId: chat, turn: turn, fragment: fragment, draft: draft.id,
			athleteText: draft.text, slash: slash)
	}

	package static func claim(
		_ attempt: AttemptID, on facts: TurnFacts?, chat: ChatID,
		device: DeviceID, process: ProcessID, lease: LeaseKind
	) -> Result<TurnClaimBody, TurnRefusal> {
		guard let facts else { return .failure(.unknownTurn) }
		if let refusal = claimRefusal(of: facts, device: device, process: process) {
			return .failure(refusal)
		}
		return .success(
			TurnClaimBody(
				chatId: chat, turn: facts.turn, attempt: attempt, process: process, lease: lease))
	}

	package static func observeReply(
		_ attempt: AttemptID, on facts: TurnFacts?, chat: ChatID
	) -> ReplyObservedBody? {
		guard let facts,
			!facts.replyObserved.contains(where: { $0.attempt == attempt })
		else { return nil }
		return ReplyObservedBody(chatId: chat, turn: facts.turn, attempt: attempt)
	}

	package static func settled(
		_ attempt: AttemptID, _ settlement: Settlement, on facts: TurnFacts?, chat: ChatID
	) -> TurnSettledBody? {
		guard let facts,
			!facts.settlements.contains(where: { $0.attempt == attempt })
		else { return nil }
		return TurnSettledBody(
			chatId: chat, turn: facts.turn, attempt: attempt, settlement: settlement)
	}

	package static func stopBeforeStart(
		_ attempt: AttemptID, on facts: TurnFacts?, chat: ChatID
	) -> Result<TurnSettledBody, TurnRefusal> {
		guard let facts else { return .failure(.unknownTurn) }
		guard facts.openClaim == nil else { return .failure(.attemptInFlight) }
		return .success(
			TurnSettledBody(
				chatId: chat, turn: facts.turn, attempt: attempt,
				settlement: .interrupted(partial: "", cause: .stoppedBeforeStart, saved: .none)))
	}

	package static func claimRefusal(of facts: TurnFacts, device: DeviceID, process: ProcessID)
		-> TurnRefusal?
	{
		if facts.origin != device {
			return .acceptedElsewhere
		}
		if facts.legacy {
			return .alreadyAnswered
		}
		if let open = facts.openClaim {
			return open.process == process ? .attemptInFlight : .unrecovered
		}
		return replayRefusal(after: facts.latestSettlement?.settlement)
	}

	package static func retryRefusal(
		of facts: TurnFacts?, overlay: TurnOverlay, device: DeviceID, process: ProcessID
	) -> TurnRefusal? {
		guard let facts else { return .unknownTurn }
		switch overlay {
		case .collecting, .queued: return .attemptInFlight
		case .waitingToTryAgain: return .rateLimitWaitRunning
		case .notInThisProcess: return claimRefusal(of: facts, device: device, process: process)
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
		device: DeviceID,
		process: ProcessID
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
		if let settlement = facts.latestSettlement?.settlement {
			let retry = replayRefusal(after: settlement) == nil ? facts.turn : nil
			switch settlement {
			case .replied(let reply, _):
				return .completed(TurnState.Completed(reply: reply))
			case .savedWork(let outcome, let saved):
				return .savedWork(
					TurnState.SavedWork(
						outcome: outcome, saved: saved,
						notice: AthleteNotices.notice(for: outcome, saved: saved))
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
		if let open = facts.openClaim {
			guard open.process == process else {
				return .unrecovered(TurnState.Unrecovered(notice: AthleteNotices.unrecoveredClaim))
			}
			return .processing(
				TurnState.Processing(
					attempt: open.attempt, liveText: "", activity: .generating(step: 1)))
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

extension LiveAttempt {
	package mutating func apply(_ progress: AttemptProgress) {
		switch progress {
		case .textDelta(let delta):
			text += delta
		case .attemptRestarted:
			text = ""
		case .activity(let next):
			activity = next
		case .proposalPending:
			return
		}
	}
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
	case turn(TurnID, origin: AttemptOrigin)
	case flush(FlushJobID)
	case reset(ResetID)

	package var turn: TurnID? {
		guard case .turn(let turn, _) = self else { return nil }
		return turn
	}

	package var reset: ResetID? {
		guard case .reset(let reset) = self else { return nil }
		return reset
	}

	package var initiator: LeaseInitiator {
		switch self {
		case .turn, .reset: .athlete
		case .flush: .recovery
		}
	}
}

package struct OpenWindow: Sendable, Equatable {
	package let turn: TurnID
	package let closesAt: Date
}

extension Duration {
	package var timeInterval: TimeInterval {
		TimeInterval(components.seconds)
			+ TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
	}
}
