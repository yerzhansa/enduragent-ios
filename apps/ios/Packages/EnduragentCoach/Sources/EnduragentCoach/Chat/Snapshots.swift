import Foundation

public struct ChatSnapshot: Sendable, Equatable {
	public let chat: ChatID
	public let opening: ConversationOpening
	public let turns: [TurnView]
	public let activity: ChatActivity
	public let review: ReviewSnapshot?
	public let notes: [TranscriptNote]
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
	package init(
		chat: ChatID,
		conversation: Conversation,
		jobs: [FlushJob],
		live: LiveAttempt?,
		window: OpenWindow?,
		queued: [TurnID],
		waiting: Set<TurnID>,
		stopping: Bool,
		resetting: Bool,
		finishedAway: Set<TurnID>,
		review: ReviewSnapshot?,
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
		} else if resetting, opening == .continuing {
			self.activity = .startingNewConversation(label: Catalog.chatNoticeWorking)
		} else {
			self.activity = .idle
		}
		self.review = review
		self.notes = current.transcriptNotes(among: turns)
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

public struct TranscriptNote: Sendable, Equatable, Identifiable {
	public let id: ULID
	public let after: TurnID?
	public let summary: ReviewSummary

	public func sentence(in phrasebook: any Phrasebook) -> String {
		phrasebook.say(
			Catalog.coachConfirmationExecuted, ["summary": summary.sentence(in: phrasebook)])
	}
}
