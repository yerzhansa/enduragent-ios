import Foundation
import Synchronization

package final class DiagnosticsLog: Sendable {
	package static let capacity = 200

	private let clock: any Clock
	private let ring = Mutex<[DiagnosticsEntry]>([])

	package init(clock: any Clock) {
		self.clock = clock
	}

	package var entries: [DiagnosticsEntry] {
		ring.withLock { $0 }
	}

	package func record(_ event: DiagnosticsEvent) {
		let entry = DiagnosticsEntry(at: clock.now, event: event)
		ring.withLock { entries in
			entries.append(entry)
			if entries.count > Self.capacity {
				entries.removeFirst(entries.count - Self.capacity)
			}
		}
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
}
