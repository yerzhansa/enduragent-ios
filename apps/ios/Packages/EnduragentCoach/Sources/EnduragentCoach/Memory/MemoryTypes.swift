import Foundation

package enum LedgerKind: String, Sendable {
	case decision
	case override
	case illness
	case experiment
	case outcome
}

package enum LedgerSource: String, Sendable {
	case flush
	case chat
}

package enum JournalOp: String, Sendable {
	case writeSection = "write-section"
	case renameSections = "rename-sections"
}

package struct MemoryHit: Sendable, Equatable {
	package var date: CivilDate
	package var kind: Kind
	package var text: String

	package init(date: CivilDate, kind: Kind, text: String) {
		self.date = date
		self.kind = kind
		self.text = text
	}

	package enum Kind: Sendable, Equatable {
		case dailyNote
		case ledger(LedgerKind)
		case journal
	}
}

package struct MemoryView: Sendable, Equatable {
	package var sections: [String: String]
	package var todayNotes: String?
	package var orphanNames: [String]

	package init(sections: [String: String], todayNotes: String?, orphanNames: [String]) {
		self.sections = sections
		self.todayNotes = todayNotes
		self.orphanNames = orphanNames
	}
}

package struct MemoryQueryFailure: Error, Equatable, Sendable {
	package var message: String

	package init(message: String) {
		self.message = message
	}
}

package enum MemoryFlushPolicy {
	package static let retryWaitAllowance: Duration = .seconds(10)
	package static let maxSteps = 5
	package static let sectionSoftWarnChars = 4000
	package static let memorySectionBudgetChars = 1500
	package static let compactionStart = "### Compaction summary"
	package static let compactionEnd = "### End of compaction summary"
	package static let stampPrefix = "_updated: "
	package static let consumedFlushKeyPrefix = "flush-consumed:"
	package static let historyPreviewChars = 200
}
