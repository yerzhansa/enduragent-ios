import Foundation

public struct ChatSnapshot: Sendable, Equatable {
	public let chat: ChatID
	public let opening: ConversationOpening
	public let turns: [TurnView]
	public let activity: ChatActivity
	public let pendingProposal: PendingProposal?
}

public struct TurnView: Sendable, Equatable, Identifiable {
	public let id: TurnID
	public let athleteText: String?
	public let sentOn: CivilDate
	public let state: TurnState
	public let completedInBackground: Bool
}

public enum ChatActivity: Sendable, Equatable {
	case idle
	case working(label: CatalogKey)
	case stopping
}

public enum ConversationOpening: Sendable, Equatable {
	case welcome
	case afterNewConversation(memorySaved: Bool)
	case continuing

	public var notice: CatalogKey? {
		switch self {
		case .afterNewConversation(memorySaved: true): Catalog.chatNoticeNewConversationSuccess
		case .afterNewConversation(memorySaved: false):
			Catalog.chatNoticeNewConversationMemoryWarning
		case .welcome, .continuing: nil
		}
	}

	package init(_ segment: Segment, jobs: [FlushJob]) {
		guard segment.turns.isEmpty else {
			self = .continuing
			return
		}
		guard case .reset(.explicit(let reset)) = segment.openedBy else {
			self = .welcome
			return
		}
		self = .afterNewConversation(
			memorySaved: jobs.first { $0.reset == reset }.map(\.settled) ?? true)
	}
}

public enum Welcome {
	package static let syncCommand = "/sync"

	public static func text(in phrasebook: any Phrasebook, showsSyncLine: Bool) -> String {
		let text = phrasebook.say(
			Catalog.telegramWelcome,
			[
				"product": "Cycling Coach", "service": "intervals.icu", "plan": "/plan",
				"workout": SlashCommand.workout.rawValue, "status": SlashCommand.status.rawValue,
				"review": SlashCommand.review.rawValue, "sync": syncCommand,
				"version": "/version", "whatsnew": "/whatsnew", "update": "/update",
				"updateDescription": phrasebook.say(Catalog.telegramMenuUpdate, [:]),
			])
		guard !showsSyncLine else { return text }
		return text.split(separator: "\n", omittingEmptySubsequences: false)
			.filter { !$0.hasPrefix(syncCommand) }
			.joined(separator: "\n")
	}
}

public enum SendOutcome: Sendable, Equatable {
	case accepted(TurnID)
	case newConversation(ResetOutcome)
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
	case rateLimitWaitRunning
	case unrecovered
}

extension ChatSnapshot {
	package init(
		chat: ChatID,
		conversation: Conversation,
		jobs: [FlushJob],
		live: LiveAttempt?,
		window: OpenWindow?,
		queued: [TurnID],
		waiting: Set<TurnID>,
		stopping: Bool,
		finishedAway: Set<TurnID>,
		pendingProposal: PendingProposal?,
		device: DeviceID,
		process: ProcessID,
		now: Date,
		zone: TimeZone
	) {
		self.chat = chat
		let current = conversation.current
		self.opening = ConversationOpening(current, jobs: jobs)
		self.turns = current.turnViews(
			live: live, window: window, queued: queued, waiting: waiting,
			finishedAway: finishedAway, device: device, process: process,
			today: CivilDate(date: now, timeZone: zone))
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

extension Segment {
	package func turnViews(
		live: LiveAttempt?, window: OpenWindow?, queued: [TurnID], waiting: Set<TurnID>,
		finishedAway: Set<TurnID>, device: DeviceID, process: ProcessID, today: CivilDate
	) -> [TurnView] {
		turns.compactMap { facts -> TurnView? in
			if hidesWholly(facts) {
				return nil
			}
			let overlay = TurnOverlay(
				of: facts.turn, window: window, queued: queued, waiting: waiting)
			return TurnView(
				id: facts.turn,
				athleteText: hidesQuestion(of: facts) ? nil : facts.requestText,
				sentOn: facts.fragments.first?.civilDate ?? today,
				state: TurnLifecycle.state(
					of: facts, live: live, overlay: overlay, device: device, process: process),
				completedInBackground: finishedAway.contains(facts.turn)
			)
		}
	}
}

extension RetryRefusal {
	package init(_ refusal: TurnRefusal) {
		switch refusal {
		case .unknownTurn: self = .unknownTurn
		case .acceptedElsewhere: self = .acceptedOnOtherDevice
		case .alreadyAnswered: self = .alreadyAnswered
		case .attemptInFlight: self = .alreadyRunning
		case .rateLimitWaitRunning: self = .rateLimitWaitRunning
		case .unrecovered: self = .unrecovered
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
