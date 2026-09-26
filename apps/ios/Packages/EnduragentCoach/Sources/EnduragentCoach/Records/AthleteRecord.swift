import Foundation

public enum RecordLocality: Sendable, Equatable {
	case synced
	case deviceLocal
}

public enum SyncedKind: String, Sendable, CaseIterable {
	case userMessage
	case turnSettled
	case windowStart
	case compactionSummary
	case memorySection
	case dailyNote
	case ledgerEvent
	case journal
	case provenance
	case coachReplyLanguage
	case planningDevice
}

public enum DeviceLocalKind: String, Sendable, CaseIterable {
	case turnClaim
	case pendingProposal
	case proposalCleared
	case flushPending
	case planningCommand
	case planRevision
	case mirrorJob
	case workoutMatch
	case workoutDrift
}

public enum LegacyKind: String, Sendable, CaseIterable {
	case userMessage
	case assistantMessage
	case windowStart
}

public enum SyncedRecordBody: Sendable, Equatable {
	case userMessage(UserMessageBody)
	case turnSettled(TurnSettledBody)
	case windowStart(WindowStartBody)
	case compactionSummary(CompactionSummaryBody)
	case memorySection(MemorySectionBody)
	case dailyNote(DailyNoteBody)
	case ledgerEvent(LedgerEventBody)
	case journal(JournalBody)
	case provenance(ProvenanceBody)
	case coachReplyLanguage(CoachReplyLanguageBody)
	case planningDevice(PlanningDeviceBody)

	public var kind: SyncedKind {
		switch self {
		case .userMessage: .userMessage
		case .turnSettled: .turnSettled
		case .windowStart: .windowStart
		case .compactionSummary: .compactionSummary
		case .memorySection: .memorySection
		case .dailyNote: .dailyNote
		case .ledgerEvent: .ledgerEvent
		case .journal: .journal
		case .provenance: .provenance
		case .coachReplyLanguage: .coachReplyLanguage
		case .planningDevice: .planningDevice
		}
	}

	public var chatId: ChatID? {
		switch self {
		case .userMessage(let body): body.chatId
		case .turnSettled(let body): body.chatId
		case .windowStart(let body): body.chatId
		case .compactionSummary(let body): body.chatId
		case .memorySection, .dailyNote, .ledgerEvent, .journal, .provenance,
			.coachReplyLanguage, .planningDevice:
			nil
		}
	}

	public var turn: TurnID? {
		switch self {
		case .userMessage(let body): body.turn
		case .turnSettled(let body): body.turn
		case .windowStart, .compactionSummary, .memorySection, .dailyNote, .ledgerEvent,
			.journal, .provenance, .coachReplyLanguage, .planningDevice:
			nil
		}
	}
}

public enum DeviceLocalRecordBody: Sendable, Equatable {
	case turnClaim(TurnClaimBody)
	case pendingProposal(ProposalBody)
	case proposalCleared(ProposalClearedBody)
	case flushPending(FlushPendingBody)
	case planningCommand(PlanningCommandBody)
	case planRevision(PlanRevisionBody)
	case mirrorJob(MirrorJobBody)
	case workoutMatch(WorkoutMatchBody)
	case workoutDrift(WorkoutDriftBody)

	public var kind: DeviceLocalKind {
		switch self {
		case .turnClaim: .turnClaim
		case .pendingProposal: .pendingProposal
		case .proposalCleared: .proposalCleared
		case .flushPending: .flushPending
		case .planningCommand: .planningCommand
		case .planRevision: .planRevision
		case .mirrorJob: .mirrorJob
		case .workoutMatch: .workoutMatch
		case .workoutDrift: .workoutDrift
		}
	}

	public var chatId: ChatID? {
		switch self {
		case .turnClaim(let body): body.chatId
		case .pendingProposal(let body): body.chatId
		case .proposalCleared(let body): body.chatId
		case .flushPending(let body): body.chatId
		case .planningCommand, .planRevision, .mirrorJob, .workoutMatch, .workoutDrift: nil
		}
	}

	public var turn: TurnID? {
		switch self {
		case .turnClaim(let body): body.turn
		case .pendingProposal, .proposalCleared, .flushPending, .planningCommand, .planRevision,
			.mirrorJob, .workoutMatch, .workoutDrift:
			nil
		}
	}
}

public enum RecordBody: Sendable, Equatable {
	case synced(SyncedRecordBody)
	case deviceLocal(DeviceLocalRecordBody)
	case legacy(LegacyRecordBody)

	public var kind: String {
		switch self {
		case .synced(let body): body.kind.rawValue
		case .deviceLocal(let body): body.kind.rawValue
		case .legacy(let body): body.kind.rawValue
		}
	}

	public var locality: RecordLocality {
		switch self {
		case .synced, .legacy: .synced
		case .deviceLocal: .deviceLocal
		}
	}

	public var chatId: ChatID? {
		switch self {
		case .synced(let body): body.chatId
		case .deviceLocal(let body): body.chatId
		case .legacy(let body): body.chatId
		}
	}

	public var turn: TurnID? {
		switch self {
		case .synced(let body): body.turn
		case .deviceLocal(let body): body.turn
		case .legacy: nil
		}
	}
}

public enum RecordCause: Hashable, Sendable {
	case operation(OperationID, AttemptID)
	case legacy
}

public struct AthleteRecord: Sendable, Equatable, Identifiable {
	public var id: ULID { ulid }
	public let ulid: ULID
	public let deviceId: DeviceID
	public let hlc: HybridLogicalClock
	public let timeZone: IANATimeZone
	public let civilDate: CivilDate
	public let cause: RecordCause
	public let account: TrainingAccount
	public let body: RecordBody

	public var locality: RecordLocality { body.locality }
	public var chatId: ChatID? { body.chatId }

	package init(
		ulid: ULID,
		deviceId: DeviceID,
		hlc: HybridLogicalClock,
		timeZone: IANATimeZone,
		civilDate: CivilDate,
		cause: RecordCause,
		account: TrainingAccount,
		body: RecordBody
	) {
		self.ulid = ulid
		self.deviceId = deviceId
		self.hlc = hlc
		self.timeZone = timeZone
		self.civilDate = civilDate
		self.cause = cause
		self.account = account
		self.body = body
	}
}
