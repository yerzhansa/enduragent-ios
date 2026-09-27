import Foundation

package enum TurnEvent: Sendable, Equatable {
	case accept(Draft, joining: TurnID?, slash: SlashCommand?)
	case claim(AttemptID, process: ProcessID)
	case observeReply(AttemptID)
	case settle(AttemptID, Settlement)
	case stopBeforeStart(AttemptID)
	case recoverDeadClaim(AttemptID, saved: WriteSummary)
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
	case unrecovered
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
		case .claim(let attempt, let process):
			guard let facts else { return .failure(.unknownTurn) }
			if let refusal = claimRefusal(of: facts, device: device, process: process) {
				return .failure(refusal)
			}
			let claim = TurnClaimBody(
				chatId: chat, turn: facts.turn, attempt: attempt, process: process)
			return .success(.local([.turnClaim(claim)]))
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
			guard facts.openClaim == nil else { return .failure(.attemptInFlight) }
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
		case .recoverDeadClaim(let attempt, let saved):
			return writes(
				for: .settle(
					attempt, .interrupted(partial: "", cause: .processEnded, saved: saved)),
				on: facts, chat: chat, device: device, mint: mint)
		}
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

	package func windowElapsed() async -> Bool {
		do {
			try await Task.sleep(for: window)
			return true
		} catch is CancellationError {
			return false
		} catch {
			fatalError("Task.sleep failed: \(error)")
		}
	}
}

package enum MailboxWork: Sendable, Equatable {
	case turn(TurnID)
	case flush(FlushJobID)
	case reset(ResetID)

	package var turn: TurnID? {
		guard case .turn(let turn) = self else { return nil }
		return turn
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
