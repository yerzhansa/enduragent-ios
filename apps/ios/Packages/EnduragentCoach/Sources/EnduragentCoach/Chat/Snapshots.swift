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
	public let reset: ResetStatus

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.chat == rhs.chat && lhs.opening == rhs.opening && lhs.turns == rhs.turns
			&& lhs.activity == rhs.activity && lhs.review == rhs.review && lhs.notes == rhs.notes
			&& lhs.liveReply == rhs.liveReply && lhs.reset == rhs.reset
	}
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
	public let saveFailure: CatalogKey?
}

public enum ChatActivity: Sendable, Equatable {
	case idle
	case working(label: CatalogKey)
	case stopping
}

public enum ConversationOpening: Sendable, Equatable {
	case welcome
	case afterNewConversation(reset: ResetID, memory: MemorySaveResult)
	case continuing

	public var showsWelcome: Bool {
		switch self {
		case .welcome, .afterNewConversation: true
		case .continuing: false
		}
	}

	public var notice: CatalogKey? {
		switch self {
		case .afterNewConversation(_, .saved): Catalog.chatNoticeNewConversationSuccess
		case .afterNewConversation:
			Catalog.chatNoticeNewConversationMemoryWarning
		case .welcome, .continuing: nil
		}
	}

	package init(_ segment: Segment, jobs: [FlushJob], memory: MemorySaveResult?) {
		if case .reset(let reset) = segment.openedBy {
			let saved = jobs.first { $0.reset == reset }.map(\.saved)
			self = .afterNewConversation(
				reset: reset,
				memory: saved == true ? .saved : memory ?? (saved == false ? .notSaved : .saved))
		} else {
			self = segment.turns.isEmpty ? .welcome : .continuing
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
	case newConversation(ResetAdmission)
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
		unsavedTurns: Set<TurnID> = [],
		review: ReviewSnapshot?,
		reset: ResetStatus = .idle,
		resetMemory: MemorySaveResult? = nil,
		device: DeviceID,
		process: ProcessID,
		now: Date,
		zone: TimeZone
	) {
		self.chat = chat
		self.revision = revision
		self.liveReply = LiveReply(phase.running?.live)
		self.reset = reset
		let items = phase.items(queued: queued)
		let boundary = items.compactMap { item -> HybridLogicalClock? in
			guard case .waiting = reset else { return nil }
			guard case .reset(let reset) = item else { return nil }
			return reset.boundary
		}.first {
			conversation.current.boundary?.precedes(.observed($0)) != false
		}
		let current = boundary.map { conversation.current.closing(at: $0) } ?? conversation.current
		self.opening = ConversationOpening(current, jobs: jobs, memory: resetMemory)
		self.turns = projection.turns(
			in: current,
			live: phase.running?.live, window: window, queued: items.compactMap(\.turn),
			waiting: waiting,
			finishedAway: finishedAway, device: device, process: process,
			unsavedTurns: unsavedTurns,
			today: CivilDate(date: now, timeZone: zone))
		if phase.cause != nil {
			self.activity = .stopping
		} else if case .waiting = reset {
			self.activity = .working(label: Catalog.chatNoticeStartingNewConversation)
		} else if window != nil || items.contains(where: { $0.turn != nil }) {
			self.activity = .working(label: Catalog.chatNoticeWorking)
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
				id: note.ulid,
				after: note.after.flatMap { anchor in turns.first { $0.id == anchor }?.id }
					?? turns.last { $0.id.ulid < note.ulid }?.id,
				content: note.content)
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
	public let content: Content

	public enum Content: Sendable, Equatable {
		case applied(ReviewSummary)
		case cancelledUnknown(CancelledUnknownReview)
	}

	public func sentence(in phrasebook: CatalogPhrasebook) -> String {
		switch content {
		case .applied(let summary):
			phrasebook.say(
				Catalog.coachConfirmationExecuted, ["summary": summary.sentence(in: phrasebook)])
		case .cancelledUnknown:
			phrasebook.say(Catalog.reviewCancelledUnknown)
		}
	}
}
