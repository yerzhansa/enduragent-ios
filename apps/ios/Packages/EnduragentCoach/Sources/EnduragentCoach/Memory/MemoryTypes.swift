import Foundation

public enum LedgerKind: String, Sendable {
	case decision
	case override
	case illness
	case experiment
	case outcome
}

public enum LedgerSource: String, Sendable {
	case flush
	case chat
}

public enum JournalOp: String, Sendable {
	case writeSection = "write-section"
	case savePlan = "save-plan"
	case renameSections = "rename-sections"
}

public enum FlushTrigger: String, Sendable {
	case trim
	case preCompaction
	case overflow
	case explicitReset
	case staleReset
	case softThreshold
}

public struct MemoryHit: Sendable, Equatable {
	public var date: CivilDate
	public var kind: Kind
	public var text: String

	public init(date: CivilDate, kind: Kind, text: String) {
		self.date = date
		self.kind = kind
		self.text = text
	}

	public enum Kind: Sendable, Equatable {
		case dailyNote
		case ledger(LedgerKind)
		case journal
	}
}

public struct MemoryView: Sendable, Equatable {
	public var sections: [String: String]
	public var todayNotes: String?
	public var planHeadline: PlanHeadline?
	public var orphanNames: [String]

	public init(
		sections: [String: String], todayNotes: String?, planHeadline: PlanHeadline?,
		orphanNames: [String]
	) {
		self.sections = sections
		self.todayNotes = todayNotes
		self.planHeadline = planHeadline
		self.orphanNames = orphanNames
	}
}

public struct PlanHeadline: Sendable, Equatable {
	public var name: String
	public var primaryGoal: String?
	public var totalWeeks: Int?
	public var status: PlanStatus?

	public init(name: String, primaryGoal: String?, totalWeeks: Int?, status: PlanStatus?) {
		self.name = name
		self.primaryGoal = primaryGoal
		self.totalWeeks = totalWeeks
		self.status = status
	}
}

public struct MemoryQueryFailure: Error, Equatable, Sendable {
	public var message: String

	public init(message: String) {
		self.message = message
	}
}

public enum MemoryFlushPolicy {
	public static let maxSteps = 5
	public static let maxAttempts = 2
	public static let sectionSoftWarnChars = 4000
	public static let flushShrinkMinChars = 200
	public static let flushShrinkRatio = 0.7
	public static let flushZeroWriteMinMessages = 4
	public static let memorySectionBudgetChars = 1500
	public static let compactionStart = "### Compaction summary"
	public static let compactionEnd = "### End of compaction summary"
	public static let stampPrefix = "_updated: "
	public static let consumedFlushKeyPrefix = "flush-consumed:"
	public static let historyPreviewChars = 200
}
