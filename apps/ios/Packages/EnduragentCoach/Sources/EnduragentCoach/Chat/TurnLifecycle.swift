import Foundation

public enum TurnState: Sendable, Equatable {
	case accepted(Accepted)
	case processing(Processing)
	case completed(Completed)
	case failed(Failed)
	case interrupted(Interrupted)

	public var retryable: Bool {
		switch self {
		case .accepted(.awaitingRestart):
			return true
		case .failed(let failed):
			if case .tryAgain = failed.notice.action {
				return true
			}
			return false
		case .interrupted(let interrupted):
			return interrupted.saved.isEmpty
		case .accepted, .processing, .completed:
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
	case compacting
	case savingMemory
}

public enum InterruptionCause: String, Sendable {
	case athleteStopped
	case processEnded
	case stoppedBeforeStart
}

package enum TurnEvent: Sendable, Equatable {
	case accept(Draft, joining: TurnID?, slash: SlashCommand?)
	case claim(AttemptID)
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
		if case .replied? = facts.latestSettlement?.settlement {
			return .alreadyAnswered
		}
		return nil
	}

	package static func state(
		of facts: TurnFacts,
		live: LiveAttempt?,
		overlay: AcceptedOverlay,
		device: DeviceID,
		now: Date
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
		case .notInThisProcess:
			break
		}
		if let latest = facts.latestSettlement {
			switch latest.settlement {
			case .replied(let reply, _):
				return .completed(TurnState.Completed(reply: reply))
			case .failed(let failure, let saved):
				return .failed(
					TurnState.Failed(
						failure: failure,
						saved: saved,
						notice: AthleteNotices.notice(for: failure, turn: facts.turn, now: now)
					))
			case .interrupted(let partial, let cause, let saved):
				return .interrupted(
					TurnState.Interrupted(
						partial: partial,
						cause: cause,
						saved: saved,
						notice: AthleteNotices.notice(for: cause, saved: saved, turn: facts.turn)
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

package struct TurnFacts: Sendable, Equatable {
	package let turn: TurnID
	package let chat: ChatID
	package let origin: DeviceID
	package var legacy = false
	package var fragments: [Fragment] = []
	package var claims: [TurnClaimBody] = []
	package var settlements: [SettledAttempt] = []

	package var requestText: String {
		fragments.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
	}

	package var slash: SlashCommand? {
		fragments.min { $0.index < $1.index }?.slash
	}

	package var latestSettlement: SettledAttempt? {
		settlements.max { $0.hlc < $1.hlc }
	}

	package var openClaims: [TurnClaimBody] {
		claims.filter { claim in !settlements.contains { $0.attempt == claim.attempt } }
	}

	var lastUlid: ULID {
		(fragments.map(\.ulid) + settlements.map(\.ulid)).max() ?? turn.ulid
	}

	var messageRows: [(ulid: ULID, message: ChatMessage)] {
		guard let first = fragments.min(by: { $0.index < $1.index }) else { return [] }
		let question = (
			first.ulid, ChatMessage(role: .user, text: requestText, civilDate: first.civilDate)
		)
		guard let settled = latestSettlement else {
			return legacy ? [question] : []
		}
		let replyText: String
		switch settled.settlement {
		case .replied(.model(let text), _):
			replyText = text
		case .interrupted(let partial, _, _) where !partial.isEmpty:
			replyText = partial
		case .interrupted, .failed:
			return []
		}
		return [
			question,
			(
				settled.ulid,
				ChatMessage(role: .assistant, text: replyText, civilDate: settled.civilDate)
			),
		]
	}
}

package struct Fragment: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let civilDate: CivilDate
	package let index: Int
	package let draft: DraftID?
	package let text: String
	package let slash: SlashCommand?
}

package struct SettledAttempt: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let civilDate: CivilDate
	package let attempt: AttemptID
	package let settlement: Settlement
}

package struct LiveAttempt: Sendable, Equatable {
	package let turn: TurnID
	package let attempt: AttemptID
	package var text: String
	package var activity: TurnActivity
}

package enum AcceptedOverlay: Sendable, Equatable {
	case collecting(until: Date)
	case queued(position: Int)
	case notInThisProcess
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
}

package struct OpenWindow: Sendable, Equatable {
	package let turn: TurnID
	package let closesAt: Date
}

package struct EnvironmentResolver: Sendable {
	package let language: @Sendable () async -> LanguagePreference

	package init(language: @escaping @Sendable () async -> LanguagePreference) {
		self.language = language
	}
}

extension Duration {
	package var timeInterval: TimeInterval {
		TimeInterval(components.seconds)
			+ TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
	}
}
