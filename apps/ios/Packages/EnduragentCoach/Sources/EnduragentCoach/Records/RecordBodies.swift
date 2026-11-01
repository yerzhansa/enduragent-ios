import Foundation

package struct UserMessageBody: Sendable, Equatable {
	package var chatId: ChatID
	package var turn: TurnID
	package var fragment: Int
	package var draft: DraftID
	package var athleteText: String
	package var slash: SlashCommand?

	package init(
		chatId: ChatID, turn: TurnID, fragment: Int, draft: DraftID, athleteText: String,
		slash: SlashCommand?
	) {
		self.chatId = chatId
		self.turn = turn
		self.fragment = fragment
		self.draft = draft
		self.athleteText = athleteText
		self.slash = slash
	}
}

package struct TurnSettledBody: Sendable, Equatable {
	package var chatId: ChatID
	package var turn: TurnID
	package var attempt: AttemptID
	package var settlement: Settlement
	package var reviewNotPrepared: ReviewNotPrepared?
	package var planSaveNotPrepared: PlanSaveNotPrepared?

	package init(
		chatId: ChatID, turn: TurnID, attempt: AttemptID, settlement: Settlement,
		reviewNotPrepared: ReviewNotPrepared? = nil, planSaveNotPrepared: PlanSaveNotPrepared? = nil
	) {
		self.chatId = chatId
		self.turn = turn
		self.attempt = attempt
		self.settlement = settlement
		self.reviewNotPrepared = reviewNotPrepared
		self.planSaveNotPrepared = planSaveNotPrepared
	}
}

package enum Settlement: Sendable, Equatable {
	case replied(ReplyText, lineage: ReplyLineage?)
	case savedWork(SavedWorkOutcome, saved: WriteSummary)
	case failed(CoachFailure, saved: WriteSummary)
	case interrupted(partial: String, cause: InterruptionCause, saved: WriteSummary)
}

package struct TurnClaimBody: Sendable, Equatable {
	package var chatId: ChatID
	package var turn: TurnID
	package var attempt: AttemptID
	package var process: ProcessID?
	package var lease: LeaseKind
}

package struct ReplyObservedBody: Sendable, Equatable {
	package var chatId: ChatID
	package var turn: TurnID
	package var attempt: AttemptID
}

package struct ReplyLineage: Sendable, Equatable {
	package var templateHash: String
	package var assembledHash: String
}

package struct WindowStartBody: Sendable, Equatable {
	package var chatId: ChatID
	package var firstIncludedUlid: ULID
	package var reason: WindowReason
	package var droppedMessageUlids: [ULID]? = nil
	package var boundaryClock: HybridLogicalClock? = nil
}

package enum WindowReason: Sendable, Equatable {
	case trim
	case compaction
	case reset(ResetID)
}

package struct CompactionSummaryBody: Sendable, Equatable {
	package var chatId: ChatID
	package var markdown: String
}

package struct MemorySectionBody: Sendable, Equatable {
	package var name: SectionName
	package var content: String
}

package struct DailyNoteBody: Sendable, Equatable {
	package var note: String
}

package struct LedgerEventBody: Sendable, Equatable {
	package var date: CivilDate
	package var kind: LedgerKind
	package var text: String
	package var source: LedgerSource
}

package struct JournalBody: Sendable, Equatable {
	package var op: JournalOp
	package var preview: String
}

package struct ProvenanceBody: Sendable, Equatable {
	package var key: String
	package var garmin: Bool
	package var nonGarmin: Bool
	package var unknown: Bool
	package var contentSha256: String
}

package struct ReviewAppliedBody: Sendable, Equatable {
	package var chatId: ChatID
	package var summary: ReviewSummary
}

package struct FlushPendingBody: Sendable, Equatable {
	package var chatId: ChatID
	package var messageUlids: [ULID]
	package var sourceBound = false
	package var process: ProcessID?
}

package struct FlushSettledBody: Sendable, Equatable {
	package var chatId: ChatID
	package var job: FlushJobID
	package var settlement: FlushSettlement
}

package enum FlushSettlement: Sendable, Equatable {
	case saved(sections: Int, events: Int)
	case nothingToSave
	case abandoned
}

package struct CoachReplyLanguageBody: Sendable, Equatable {
	package var tag: LanguageTag?
}

package struct SessionSettingsBody: Sendable, Equatable {
	package var settings: SessionSettings
}

package struct LanguagePreferenceBody: Sendable, Equatable {
	package var preference: LanguagePreference
}

package struct PlanningDeviceBody: Sendable, Equatable {
	package var planningDeviceId: DeviceID
	package var planUlid: ULID
	package var activatedAt: Date
}
