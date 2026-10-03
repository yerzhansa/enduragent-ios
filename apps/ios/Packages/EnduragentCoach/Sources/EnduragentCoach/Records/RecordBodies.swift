import Foundation

package struct UserMessageBody: Sendable, Equatable {
	package var chatId: ChatID
	package var turn: TurnID
	package var fragment: Int
	package var draft: DraftID
	package var athleteText: String
	package var slash: SlashCommand?
}

package struct TurnSettledBody: Sendable, Equatable {
	package var chatId: ChatID
	package var turn: TurnID
	package var attempt: AttemptID
	package var settlement: Settlement
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

package struct ProposalBody: Sendable, Equatable {
	package var writeID: CalendarWriteID? = nil
	package var chatId: ChatID
	package var nonce: Nonce
	package var tool: GatedToolName
	package var toolInput: GatedToolInput
	package var summary: String
	package var description: String
	package var expiresAt: Date
}

package struct ProposalClearedBody: Sendable, Equatable {
	package var chatId: ChatID
	package var nonce: Nonce
	package var reason: ProposalClearReason
}

package enum ProposalClearReason: String, Sendable {
	case executed
	case replaced
	case expired
	case canceled
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

package struct PlanningCommandBody: Sendable, Equatable {
	package var commandName: PlanningCommandName
	package var commandId: String
	package var requestDigest: String
	package var status: PlanningCommandStatus
	package var result: JSONValue?
}

package struct PlanRevisionBody: Sendable, Equatable {
	package var planUlid: ULID
	package var version: Int
	package var status: PlanStatus
	package var snapshot: JSONValue
}

package struct MirrorJobBody: Sendable, Equatable {
	package var planUlid: ULID
	package var kind: MirrorJobKind
	package var windowStart: DateKey
	package var windowEnd: DateKey
	package var failureCount: Int
}

package struct WorkoutMatchBody: Sendable, Equatable {
	package var planWorkoutId: ULID
	package var activityId: String
	package var decision: MatchDecision
}

package struct WorkoutDriftBody: Sendable, Equatable {
	package var planWorkoutId: ULID
	package var askedAt: Date
}
