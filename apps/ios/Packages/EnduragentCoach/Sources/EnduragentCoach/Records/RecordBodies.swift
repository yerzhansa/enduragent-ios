import Foundation

public struct UserMessageBody: Sendable, Equatable {
	public var chatId: ChatID
	public var turn: TurnID
	public var fragment: Int
	public var draft: DraftID
	public var athleteText: String
	public var slash: SlashCommand?
}

public struct TurnSettledBody: Sendable, Equatable {
	public var chatId: ChatID
	public var turn: TurnID
	public var attempt: AttemptID
	public var settlement: Settlement
}

public enum Settlement: Sendable, Equatable {
	case replied(ReplyText, lineage: ReplyLineage?)
}

public enum ReplyText: Sendable, Equatable {
	case model(String)
}

public struct ReplyLineage: Sendable, Equatable {
	public var templateHash: String
	public var assembledHash: String
}

public struct WindowStartBody: Sendable, Equatable {
	public var chatId: ChatID
	public var firstIncludedUlid: ULID
	public var reason: WindowReason
}

public enum WindowReason: Sendable, Equatable {
	case trim
	case compaction
	case reset(ResetKind)
}

public enum ResetKind: Sendable, Equatable {
	case explicit(ResetID)
	case daily
	case idle
}

public struct CompactionSummaryBody: Sendable, Equatable {
	public var chatId: ChatID
	public var markdown: String
}

public struct MemorySectionBody: Sendable, Equatable {
	public var name: SectionName
	public var content: String
}

public struct DailyNoteBody: Sendable, Equatable {
	public var note: String
}

public struct LedgerEventBody: Sendable, Equatable {
	public var date: CivilDate
	public var kind: LedgerKind
	public var text: String
	public var source: LedgerSource
}

public struct JournalBody: Sendable, Equatable {
	public var op: JournalOp
	public var preview: String
}

public struct ProvenanceBody: Sendable, Equatable {
	public var key: String
	public var garmin: Bool
	public var nonGarmin: Bool
	public var unknown: Bool
	public var contentSha256: String
}

public struct ProposalBody: Sendable, Equatable {
	public var chatId: ChatID
	public var nonce: Nonce
	public var tool: GatedToolName
	public var toolInput: GatedToolInput
	public var summary: String
	public var description: String
	public var expiresAt: Date
}

public struct ProposalClearedBody: Sendable, Equatable {
	public var chatId: ChatID
	public var nonce: Nonce
	public var reason: ProposalClearReason
}

public enum ProposalClearReason: String, Sendable {
	case executed
	case replaced
	case expired
	case cancelled
}

public struct FlushPendingBody: Sendable, Equatable {
	public var chatId: ChatID
	public var trigger: FlushTrigger
	public var messageUlids: [ULID]
}

public struct CoachReplyLanguageBody: Sendable, Equatable {
	public var tag: LanguageTag?
}

public struct PlanningDeviceBody: Sendable, Equatable {
	public var planningDeviceId: DeviceID
	public var planUlid: ULID
	public var activatedAt: Date
}

public struct PlanningCommandBody: Sendable, Equatable {
	public var commandName: PlanningCommandName
	public var commandId: String
	public var requestDigest: String
	public var status: PlanningCommandStatus
	public var result: JSONValue?
}

public struct PlanRevisionBody: Sendable, Equatable {
	public var planUlid: ULID
	public var version: Int
	public var status: PlanStatus
	public var snapshot: JSONValue
}

public struct MirrorJobBody: Sendable, Equatable {
	public var planUlid: ULID
	public var kind: MirrorJobKind
	public var windowStart: DateKey
	public var windowEnd: DateKey
	public var failureCount: Int
}

public struct WorkoutMatchBody: Sendable, Equatable {
	public var planWorkoutId: ULID
	public var activityId: String
	public var decision: MatchDecision
}

public struct WorkoutDriftBody: Sendable, Equatable {
	public var planWorkoutId: ULID
	public var askedAt: Date
}
