import Foundation

public struct ChatSnapshot: Sendable, Equatable {
	public let chat: ChatID
	public let turns: [TurnView]
	public let activity: ChatActivity
	public let pendingProposal: PendingProposal?
}

public struct TurnView: Sendable, Equatable, Identifiable {
	public let id: TurnID
	public let athleteText: String
	public let sentOn: CivilDate
	public let state: TurnState
}

public enum ChatActivity: Sendable, Equatable {
	case idle
	case working(label: CatalogKey)
	case stopping
}

public enum SendOutcome: Sendable, Equatable {
	case accepted(TurnID)
	case showLanguagePicker
	case ignoredBlank
}

public enum AcceptFailure: Error, Sendable, Equatable {
	case storageUnavailable
}

public enum RetryRefusal: Error, Sendable, Equatable {
	case unknownTurn
	case acceptedOnOtherDevice
	case alreadyAnswered
	case alreadyRunning
}

extension ChatSnapshot {
	package init(
		chat: ChatID,
		conversation: Conversation,
		live: LiveAttempt?,
		window: OpenWindow?,
		queued: [TurnID],
		stopping: Bool,
		pendingProposal: PendingProposal?,
		device: DeviceID,
		now: Date,
		zone: TimeZone
	) {
		self.chat = chat
		self.turns = conversation.current.turns.map { facts -> TurnView in
			let overlay: AcceptedOverlay
			if let window, window.turn == facts.turn {
				overlay = .collecting(until: window.closesAt)
			} else if let index = queued.firstIndex(of: facts.turn) {
				overlay = .queued(position: index + 1)
			} else {
				overlay = .notInThisProcess
			}
			return TurnView(
				id: facts.turn,
				athleteText: facts.requestText,
				sentOn: facts.fragments.first?.civilDate ?? CivilDate(date: now, timeZone: zone),
				state: TurnLifecycle.state(
					of: facts, live: live, overlay: overlay, device: device, now: now)
			)
		}
		if stopping {
			self.activity = .stopping
		} else if live != nil || window != nil || !queued.isEmpty {
			self.activity = .working(label: Catalog.chatNoticeWorking)
		} else {
			self.activity = .idle
		}
		self.pendingProposal = pendingProposal
	}
}

extension RetryRefusal {
	package init(_ refusal: TurnRefusal) {
		switch refusal {
		case .unknownTurn: self = .unknownTurn
		case .acceptedElsewhere: self = .acceptedOnOtherDevice
		case .alreadyAnswered: self = .alreadyAnswered
		case .attemptInFlight: self = .alreadyRunning
		}
	}
}

extension PendingProposal {
	package init(_ body: ProposalBody) {
		self.init(
			chatId: body.chatId,
			nonce: body.nonce,
			summary: body.summary,
			description: body.description,
			expiresAt: body.expiresAt
		)
	}
}
