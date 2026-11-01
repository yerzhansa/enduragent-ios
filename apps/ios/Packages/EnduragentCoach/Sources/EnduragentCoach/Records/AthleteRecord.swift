import Foundation

package enum RecordLocality: Sendable, Hashable {
	case synced
	case deviceLocal
}

package enum SyncedKind: String, Sendable, CaseIterable {
	case userMessage
	case attemptQuestion
	case turnSettled
	case windowStart
	case compactionSummary
	case memorySection
	case dailyNote
	case ledgerEvent
	case journal
	case provenance
	case coachReplyLanguage
	case reviewOutcome
	case sessionSettings
	case languagePreference
	case trainingIdentityObserved
	case savedPlan
}

package enum DeviceLocalKind: String, Sendable, CaseIterable {
	case openRouterKeyRejected
	case providerConsent
	case turnClaim
	case replyObserved
	case pendingSettlement
	case flushPending
	case flushSettled
	case workoutReview
	case reviewPreparing
	case planConfirmation
}

package enum LegacyKind: String, Sendable, CaseIterable {
	case userMessage
	case assistantMessage
	case windowStart
	case pendingProposal
	case proposalCleared
	case reviewWrite
	case reviewCancelledUnknown
	case reviewApplied
	case planningDevice

	package var locality: RecordLocality {
		switch self {
		case .pendingProposal, .proposalCleared: .deviceLocal
		case .userMessage, .assistantMessage, .windowStart, .reviewWrite, .reviewCancelledUnknown,
			.reviewApplied, .planningDevice:
			.synced
		}
	}

	var lastStoredVersion: Int {
		switch self {
		case .userMessage, .assistantMessage, .windowStart, .planningDevice: 1
		case .pendingProposal, .proposalCleared, .reviewWrite, .reviewCancelledUnknown,
			.reviewApplied:
			2
		}
	}
}

package enum SyncedRecordBody: Sendable, Equatable {
	case userMessage(UserMessageBody)
	case attemptQuestion(AttemptQuestionBody)
	case turnSettled(TurnSettledBody)
	case windowStart(WindowStartBody)
	case compactionSummary(CompactionSummaryBody)
	case memorySection(MemorySectionBody)
	case dailyNote(DailyNoteBody)
	case ledgerEvent(LedgerEventBody)
	case journal(JournalBody)
	case provenance(ProvenanceBody)
	case coachReplyLanguage(CoachReplyLanguageBody)
	case reviewOutcome(ReviewOutcomeBody)
	case sessionSettings(SessionSettingsBody)
	case languagePreference(LanguagePreferenceBody)
	case trainingIdentityObserved
	case savedPlan(SavedPlanBody)

	package var kind: SyncedKind {
		switch self {
		case .userMessage: .userMessage
		case .attemptQuestion: .attemptQuestion
		case .turnSettled: .turnSettled
		case .windowStart: .windowStart
		case .compactionSummary: .compactionSummary
		case .memorySection: .memorySection
		case .dailyNote: .dailyNote
		case .ledgerEvent: .ledgerEvent
		case .journal: .journal
		case .provenance: .provenance
		case .coachReplyLanguage: .coachReplyLanguage
		case .reviewOutcome: .reviewOutcome
		case .sessionSettings: .sessionSettings
		case .languagePreference: .languagePreference
		case .trainingIdentityObserved: .trainingIdentityObserved
		case .savedPlan: .savedPlan
		}
	}

	package var chatId: ChatID? {
		switch self {
		case .userMessage(let body): body.chatId
		case .attemptQuestion(let body): body.chatId
		case .turnSettled(let body): body.chatId
		case .windowStart(let body): body.chatId
		case .compactionSummary(let body): body.chatId
		case .reviewOutcome(let body): body.chatId
		case .memorySection, .dailyNote, .ledgerEvent, .journal, .provenance,
			.coachReplyLanguage, .sessionSettings, .languagePreference, .trainingIdentityObserved,
			.savedPlan:
			nil
		}
	}

	package var turn: TurnID? {
		switch self {
		case .userMessage(let body): body.turn
		case .attemptQuestion(let body): body.turn
		case .turnSettled(let body): body.turn
		case .windowStart, .compactionSummary, .memorySection, .dailyNote, .ledgerEvent,
			.journal, .provenance, .coachReplyLanguage, .sessionSettings, .languagePreference,
			.reviewOutcome, .trainingIdentityObserved, .savedPlan:
			nil
		}
	}
}

package enum DeviceLocalRecordBody: Sendable, Equatable {
	case openRouterKeyRejected(OpenRouterCredentialRef)
	case providerConsent(ProviderConsent)
	case turnClaim(TurnClaimBody)
	case replyObserved(ReplyObservedBody)
	case pendingSettlement(TurnSettledBody)
	case flushPending(FlushPendingBody)
	case flushSettled(FlushSettledBody)
	case workoutReview(WorkoutReviewBody)
	case reviewPreparing(ReviewPreparingBody)
	case planConfirmation(PlanConfirmationBody)

	package var kind: DeviceLocalKind {
		switch self {
		case .openRouterKeyRejected: .openRouterKeyRejected
		case .providerConsent: .providerConsent
		case .turnClaim: .turnClaim
		case .replyObserved: .replyObserved
		case .pendingSettlement: .pendingSettlement
		case .flushPending: .flushPending
		case .flushSettled: .flushSettled
		case .workoutReview: .workoutReview
		case .reviewPreparing: .reviewPreparing
		case .planConfirmation: .planConfirmation
		}
	}

	package var chatId: ChatID? {
		switch self {
		case .turnClaim(let body): body.chatId
		case .replyObserved(let body): body.chatId
		case .pendingSettlement(let body): body.chatId
		case .flushPending(let body): body.chatId
		case .flushSettled(let body): body.chatId
		case .workoutReview(let body): body.chatId
		case .reviewPreparing(let body): body.chatId
		case .planConfirmation(let body): body.chat
		case .openRouterKeyRejected, .providerConsent:
			nil
		}
	}

	package var turn: TurnID? {
		switch self {
		case .turnClaim(let body): body.turn
		case .replyObserved(let body): body.turn
		case .pendingSettlement(let body): body.turn
		case .reviewPreparing(let body): body.turn
		case .planConfirmation(let body): body.turn
		case .openRouterKeyRejected, .providerConsent, .flushPending, .flushSettled,
			.workoutReview:
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
		case .synced: .synced
		case .deviceLocal: .deviceLocal
		case .legacy(let body): body.kind.locality
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
