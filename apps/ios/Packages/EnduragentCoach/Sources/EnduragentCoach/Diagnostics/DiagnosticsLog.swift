import Foundation
import Synchronization

package final class DiagnosticsLog: Sendable {
	package let clock: any Clock
	private let journal: Journal
	private let events = Mutex<[DiagnosticsEntry]>([])

	package init(clock: any Clock, storage: any JournalStorage) {
		self.clock = clock
		journal = Journal(storage: storage, clock: clock)
		for opening in journal.openings {
			record(opening.event)
		}
	}

	package var entries: [DiagnosticsEntry] {
		events.withLock { $0 }
	}

	package var health: JournalHealth {
		journal.health
	}

	package func healthChanges() -> AsyncStream<JournalHealth> {
		journal.healthChanges()
	}

	package func record(_ event: DiagnosticsEvent) {
		let entry = DiagnosticsEntry(at: clock.now, event: event)
		events.withLock { $0.append(entry) }
		write(StampedLine(at: entry.at, line: .problem(event.line)))
	}

	package func recordUsage(_ line: UsageLine) {
		write(StampedLine(at: clock.now, line: .usage(line)))
	}

	func recordUnwritableLine() {
		journal.markAppendFailed()
	}

	package func window(endingAt now: Date) -> [StampedLine] {
		journal.window(endingAt: now)
	}

	private func write(_ line: StampedLine) {
		let record: JournalRecord
		do {
			record = try JournalRecord(line)
		} catch {
			journal.markAppendFailed()
			return
		}
		journal.append(record)
	}
}

package struct DiagnosticsEntry: Sendable, Equatable {
	package let at: Date
	package let event: DiagnosticsEvent
}

package enum DiagnosticsEvent: Sendable, Equatable {
	case providerFailure(AttemptID, ProviderFailure, detail: ProviderDetail)
	case toolFailed(AttemptID, ToolName, failure: ToolFault)
	case memoryFlushFailed(ChatID, FailureCode)
	case compactionFailed(ChatID, FailureCode)
	case replyObservedUnsaved(AttemptID, FailureCode)
	case skippedRecord(SkippedRow)
	case recoveryUnavailable(LedgerFailure)
	case importsUnavailable(ChatID, LedgerFailure)
	case secureStorageFailed(CredentialSlot, failure: KeychainStoreError)
	case preferencesUnavailable(LedgerFailure)
	case consentUnavailable(AccessUnavailable)
	case snapshotReadFailed(AttemptID, SnapshotLineKind, TrainingFailure)
	case snapshotDeadlineMissed(AttemptID)
	case reviewOutcomeUnsaved(LedgerFailure)
	case settlementUnsaved(TurnID, LedgerFailure)
	case reviewUnavailable(ChatID, LedgerFailure)
	case planConfirmationUnavailable(ChatID, LedgerFailure)
	case planSaveStalled(PlanConfirmationID, LedgerFailure)
	case journalRestarted(JournalFault)
	case journalLinesDropped(count: Int)
	case diagnosticsFileFailed(DiagnosticsFileFailure, FailureCode)
}

extension JournalOpening {
	fileprivate var event: DiagnosticsEvent {
		switch self {
		case .linesDropped(let count): .journalLinesDropped(count: count)
		case .restarted(let fault): .journalRestarted(fault)
		}
	}
}
