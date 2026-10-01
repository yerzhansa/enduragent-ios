import Foundation

public struct ChatSnapshot: Sendable, Equatable {
	public let chat: ChatID
	public let opening: ConversationOpening
	public let turns: [TurnView]
	public let activity: ChatActivity
	public let review: ReviewSnapshot?
	public let notes: [TurnID?: [TranscriptNote]]
	public internal(set) var liveReply: LiveReply?
	public internal(set) var revision: UInt64
}

public struct LiveReply: Sendable, Equatable {
	public let turn: TurnID
	public let text: String

	init?(_ live: LiveAttempt?) {
		guard let live else { return nil }
		self.turn = live.turn
		self.text = live.text
	}
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
	case startingNewConversation(label: CatalogKey)
	case stopping
}

public enum ConversationOpening: Sendable, Equatable {
	case welcome
	case afterNewConversation(memorySaved: Bool)
	case continuing

	public var showsWelcome: Bool {
		switch self {
		case .welcome, .afterNewConversation: true
		case .continuing: false
		}
	}

	public var notice: CatalogKey? {
		switch self {
		case .afterNewConversation(memorySaved: true): Catalog.chatNoticeNewConversationSuccess
		case .afterNewConversation(memorySaved: false):
			Catalog.chatNoticeNewConversationMemoryWarning
		case .welcome, .continuing: nil
		}
	}

	package init(_ segment: Segment, jobs: [FlushJob]) {
		switch (segment.openedBy, segment.turns.isEmpty) {
		case (.reset(let reset), true):
			self = .afterNewConversation(
				memorySaved: jobs.first { $0.reset == reset }.map(\.saved) ?? true)
		case (_, true):
			self = .welcome
		case (_, false):
			self = .continuing
		}
	}
}

public enum Welcome {
	public static func text(in phrasebook: CatalogPhrasebook) -> String {
		let commands = SlashCommand.allCases.map { command in
			phrasebook.say(
				Catalog.chatWelcomeCommand,
				[
					"command": command.rawValue,
					"description": phrasebook.say(command.menuTitle, [:]),
				])
		}.joined(separator: "\n")
		return phrasebook.say(
			Catalog.chatWelcome,
			["product": "Cycling Coach", "service": "intervals.icu", "commands": commands])
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

public struct CoachStatus: Sendable, Equatable {
	public let providerConsent: ProviderConsent?
	public var needsProviderConsent: Bool {
		setup == .needsProviderConsent
	}
	public let setup: SetupState
	public let training: TrainingStatus
	public let language: LanguagePreference
	public let session: SessionSettings

	package init(
		setup: SetupState, training: TrainingStatus, preferences: Preferences,
		providerConsent: ProviderConsent? = nil
	) {
		self.providerConsent = providerConsent
		self.setup = setup
		self.training = training
		self.language = preferences.language
		self.session = preferences.session
	}

	public var notice: AthleteNotice? {
		AthleteNotices.notice(for: self)
	}

	package var trainingAccount: TrainingAccount? {
		switch training {
		case .unconnected: .unconnected
		case .connected(_, let account): account
		case .unavailable: nil
		}
	}
}

public enum SetupState: Sendable, Equatable {
	case needsProviderConsent
	case needsAccessMethod
	case ready
	case accessTemporarilyUnavailable(AccessUnavailable)
}

public enum TrainingStatus: Sendable, Equatable {
	case unconnected
	case connected(IntervalsSummary, account: TrainingAccount)
	case unavailable(AccessUnavailable)
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
	init(
		chat: ChatID,
		revision: UInt64,
		projection: inout TurnProjection,
		conversation: Conversation,
		jobs: [FlushJob],
		phase: MailboxPhase,
		window: OpenWindow?,
		queued: [MailboxWork],
		waiting: Set<TurnID>,
		finishedAway: Set<TurnID>,
		review: ReviewSnapshot?,
		device: DeviceID,
		process: ProcessID,
		now: Date,
		zone: TimeZone
	) {
		self.chat = chat
		self.revision = revision
		self.liveReply = LiveReply(phase.running?.live)
		let current = conversation.current
		let items = phase.items(queued: queued)
		self.opening = ConversationOpening(current, jobs: jobs)
		self.turns = projection.turns(
			in: current,
			live: phase.running?.live, window: window, queued: items.compactMap(\.turn),
			waiting: waiting,
			finishedAway: finishedAway, device: device, process: process,
			today: CivilDate(date: now, timeZone: zone))
		if phase.cause != nil {
			self.activity = .stopping
		} else if window != nil || items.contains(where: { $0.turn != nil }) {
			self.activity = .working(label: Catalog.chatNoticeWorking)
		} else if items.contains(where: { $0.reset != nil }), opening == .continuing {
			self.activity = .startingNewConversation(label: Catalog.chatNoticeWorking)
		} else {
			self.activity = .idle
		}
		self.review = review
		self.notes = Dictionary(grouping: current.transcriptNotes(among: turns), by: \.after)
	}
}

extension Segment {
	package func transcriptNotes(among turns: [TurnView]) -> [TranscriptNote] {
		notes.map { note in
			TranscriptNote(
				id: note.ulid, after: turns.last { $0.id.ulid < note.ulid }?.id,
				summary: note.summary)
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

public struct TranscriptNote: Sendable, Equatable, Identifiable {
	public let id: ULID
	public let after: TurnID?
	public let summary: ReviewSummary

	public func sentence(in phrasebook: CatalogPhrasebook) -> String {
		phrasebook.say(
			Catalog.coachConfirmationExecuted, ["summary": summary.sentence(in: phrasebook)])
	}
}
