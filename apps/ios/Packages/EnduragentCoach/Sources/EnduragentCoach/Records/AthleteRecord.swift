import Foundation

package enum RecordLocality: Sendable, Equatable {
	case synced
	case deviceLocal
}

package enum SyncedKind: String, Sendable, CaseIterable {
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
	case reviewApplied
	case reviewWrite
	case reviewCancelledUnknown
	case sessionSettings
	case languagePreference
	case trainingIdentityObserved
}

package enum DeviceLocalKind: String, Sendable, CaseIterable {
	case providerConsent
	case turnClaim
	case replyObserved
	case pendingSettlement
	case pendingProposal
	case proposalCleared
	case flushPending
	case flushSettled
	case planningCommand
	case planRevision
	case mirrorJob
	case workoutMatch
	case workoutDrift
}

package enum LegacyKind: String, Sendable, CaseIterable {
	case userMessage
	case assistantMessage
	case windowStart
}

package enum SyncedRecordBody: Sendable, Equatable {
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
	case reviewApplied(ReviewAppliedBody)
	case reviewWrite(ReviewWriteBody)
	case reviewCancelledUnknown(ReviewCancelledUnknownBody)
	case sessionSettings(SessionSettingsBody)
	case languagePreference(LanguagePreferenceBody)
	case trainingIdentityObserved

	package var kind: SyncedKind {
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
		case .reviewApplied: .reviewApplied
		case .reviewWrite: .reviewWrite
		case .reviewCancelledUnknown: .reviewCancelledUnknown
		case .sessionSettings: .sessionSettings
		case .languagePreference: .languagePreference
		case .trainingIdentityObserved: .trainingIdentityObserved
		}
	}

	package var chatId: ChatID? {
		switch self {
		case .userMessage(let body): body.chatId
		case .turnSettled(let body): body.chatId
		case .windowStart(let body): body.chatId
		case .compactionSummary(let body): body.chatId
		case .reviewApplied(let body): body.chatId
		case .reviewWrite(let body): body.chatId
		case .reviewCancelledUnknown(let body): body.chatId
		case .memorySection, .dailyNote, .ledgerEvent, .journal, .provenance,
			.coachReplyLanguage, .planningDevice, .sessionSettings, .languagePreference,
			.trainingIdentityObserved:
			nil
		}
	}

	package var turn: TurnID? {
		switch self {
		case .userMessage(let body): body.turn
		case .turnSettled(let body): body.turn
		case .windowStart, .compactionSummary, .memorySection, .dailyNote, .ledgerEvent,
			.journal, .provenance, .coachReplyLanguage, .planningDevice, .sessionSettings,
			.languagePreference, .reviewApplied, .reviewWrite, .reviewCancelledUnknown,
			.trainingIdentityObserved:
			nil
		}
	}
}

package enum DeviceLocalRecordBody: Sendable, Equatable {
	case providerConsent(ProviderConsent)
	case turnClaim(TurnClaimBody)
	case replyObserved(ReplyObservedBody)
	case pendingSettlement(TurnSettledBody)
	case pendingProposal(ProposalBody)
	case proposalCleared(ProposalClearedBody)
	case flushPending(FlushPendingBody)
	case flushSettled(FlushSettledBody)
	case planningCommand(PlanningCommandBody)
	case planRevision(PlanRevisionBody)
	case mirrorJob(MirrorJobBody)
	case workoutMatch(WorkoutMatchBody)
	case workoutDrift(WorkoutDriftBody)

	package var kind: DeviceLocalKind {
		switch self {
		case .providerConsent: .providerConsent
		case .turnClaim: .turnClaim
		case .replyObserved: .replyObserved
		case .pendingSettlement: .pendingSettlement
		case .pendingProposal: .pendingProposal
		case .proposalCleared: .proposalCleared
		case .flushPending: .flushPending
		case .flushSettled: .flushSettled
		case .planningCommand: .planningCommand
		case .planRevision: .planRevision
		case .mirrorJob: .mirrorJob
		case .workoutMatch: .workoutMatch
		case .workoutDrift: .workoutDrift
		}
	}

	package var chatId: ChatID? {
		switch self {
		case .turnClaim(let body): body.chatId
		case .replyObserved(let body): body.chatId
		case .pendingSettlement(let body): body.chatId
		case .pendingProposal(let body): body.chatId
		case .proposalCleared(let body): body.chatId
		case .flushPending(let body): body.chatId
		case .flushSettled(let body): body.chatId
		case .providerConsent, .planningCommand, .planRevision, .mirrorJob, .workoutMatch,
			.workoutDrift:
			nil
		}
	}

	package var turn: TurnID? {
		switch self {
		case .turnClaim(let body): body.turn
		case .replyObserved(let body): body.turn
		case .pendingSettlement(let body): body.turn
		case .providerConsent, .pendingProposal, .proposalCleared, .flushPending, .flushSettled,
			.planningCommand,
			.planRevision, .mirrorJob, .workoutMatch, .workoutDrift:
			nil
		}
	}
}

package enum RecordBody: Sendable, Equatable {
	case synced(SyncedRecordBody)
	case deviceLocal(DeviceLocalRecordBody)
	case legacy(LegacyRecordBody)

	package var kind: String {
		switch self {
		case .synced(let body): body.kind.rawValue
		case .deviceLocal(let body): body.kind.rawValue
		case .legacy(let body): body.kind.rawValue
		}
	}

	package var locality: RecordLocality {
		switch self {
		case .synced, .legacy: .synced
		case .deviceLocal: .deviceLocal
		}
	}

	package var chatId: ChatID? {
		switch self {
		case .synced(let body): body.chatId
		case .deviceLocal(let body): body.chatId
		case .legacy(let body): body.chatId
		}
	}

	package var turn: TurnID? {
		switch self {
		case .synced(let body): body.turn
		case .deviceLocal(let body): body.turn
		case .legacy: nil
		}
	}
}

package enum RecordCause: Hashable, Sendable {
	case operation(OperationID, AttemptID)
	case legacy
}

package struct AthleteRecord: Sendable, Equatable, Identifiable {
	package var id: ULID { ulid }
	package let ulid: ULID
	package let deviceId: DeviceID
	package let hlc: HybridLogicalClock
	package let timeZone: IANATimeZone
	package let civilDate: CivilDate
	package let cause: RecordCause
	package let account: TrainingAccount
	package let body: RecordBody

	package var locality: RecordLocality { body.locality }
	package var chatId: ChatID? { body.chatId }

	func replacingBody(_ body: RecordBody) -> AthleteRecord {
		AthleteRecord(
			ulid: ulid, deviceId: deviceId, hlc: hlc, timeZone: timeZone,
			civilDate: civilDate, cause: cause, account: account, body: body)
	}

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
