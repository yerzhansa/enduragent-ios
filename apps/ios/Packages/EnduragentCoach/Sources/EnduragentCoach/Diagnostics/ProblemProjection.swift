import Foundation

package enum ProblemKind: String, Sendable, Codable, CaseIterable {
	case providerFailure
	case toolFailed
	case memoryFlushFailed
	case compactionFailed
	case replyObservedUnsaved
	case skippedRecord
	case recoveryUnavailable
	case importsUnavailable
	case secureStorageFailed
	case preferencesUnavailable
	case consentUnavailable
	case snapshotReadFailed
	case snapshotDeadlineMissed
	case reviewOutcomeUnsaved
	case settlementUnsaved
	case reviewUnavailable
	case planConfirmationUnavailable
	case planSaveStalled
	case journalRestarted
	case journalLinesDropped
	case diagnosticsFileFailed
}

extension DiagnosticsEvent {
	package var line: ProblemLine {
		switch self {
		case .providerFailure(let attempt, let failure, let detail):
			ProblemLine(
				.providerFailure, subject: .attempt(attempt.ulid),
				cause: FailureCode.provider(failure).code, detail: detail.code)
		case .toolFailed(let attempt, let tool, let failure):
			ProblemLine(
				.toolFailed, subject: .attempt(attempt.ulid),
				cause: ProblemCode(caseOf: tool).then(failure.code))
		case .memoryFlushFailed(let chat, let failure):
			ProblemLine(.memoryFlushFailed, subject: Self.subject(chat), cause: failure.code)
		case .compactionFailed(let chat, let failure):
			ProblemLine(.compactionFailed, subject: Self.subject(chat), cause: failure.code)
		case .replyObservedUnsaved(let attempt, let failure):
			ProblemLine(.replyObservedUnsaved, subject: .attempt(attempt.ulid), cause: failure.code)
		case .skippedRecord(let row):
			ProblemLine(.skippedRecord, cause: row.code, row: row.text)
		case .recoveryUnavailable(let failure):
			ProblemLine(.recoveryUnavailable, cause: FailureCode.ledger(failure).code)
		case .importsUnavailable(let chat, let failure):
			ProblemLine(
				.importsUnavailable, subject: Self.subject(chat),
				cause: FailureCode.ledger(failure).code)
		case .secureStorageFailed(let slot, let failure):
			ProblemLine(
				.secureStorageFailed, subject: .slot(CredentialSlotCode(slot)),
				cause: FailureCode.keychain(failure).code)
		case .preferencesUnavailable(let failure):
			ProblemLine(.preferencesUnavailable, cause: FailureCode.ledger(failure).code)
		case .consentUnavailable(let failure):
			ProblemLine(.consentUnavailable, cause: FailureCode.access(failure).code)
		case .snapshotReadFailed(let attempt, let kind, let failure):
			ProblemLine(
				.snapshotReadFailed, subject: .attempt(attempt.ulid),
				cause: FailureCode.training(failure).code, detail: kind.code)
		case .snapshotDeadlineMissed(let attempt):
			ProblemLine(.snapshotDeadlineMissed, subject: .attempt(attempt.ulid))
		case .reviewOutcomeUnsaved(let failure):
			ProblemLine(.reviewOutcomeUnsaved, cause: FailureCode.ledger(failure).code)
		case .settlementUnsaved(let turn, let failure):
			ProblemLine(
				.settlementUnsaved, subject: .turn(turn.ulid),
				cause: FailureCode.ledger(failure).code)
		case .reviewUnavailable(let chat, let failure):
			ProblemLine(
				.reviewUnavailable, subject: Self.subject(chat),
				cause: FailureCode.ledger(failure).code)
		case .planConfirmationUnavailable(let chat, let failure):
			ProblemLine(
				.planConfirmationUnavailable, subject: Self.subject(chat),
				cause: FailureCode.ledger(failure).code)
		case .planSaveStalled(let confirmation, let failure):
			ProblemLine(
				.planSaveStalled, subject: .confirmation(confirmation.ulid),
				cause: FailureCode.ledger(failure).code)
		case .journalRestarted(let fault):
			ProblemLine(.journalRestarted, cause: fault.code)
		case .journalLinesDropped(let count):
			ProblemLine(.journalLinesDropped, cause: ProblemCode("undecodable", count))
		case .diagnosticsFileFailed(let failure, let code):
			ProblemLine(.diagnosticsFileFailed, cause: code.code, detail: failure.code)
		}
	}

	private static func subject(_ chat: ChatID) -> ProblemSubject? {
		ChatRef(chat).map(ProblemSubject.chat)
	}
}

extension SkippedRow {
	fileprivate var code: ProblemCode {
		switch self {
		case .newerKind: ProblemCode("newerKind")
		case .newerVersion(_, let version, _): ProblemCode("newerVersion", version)
		case .malformed: ProblemCode("malformed")
		}
	}

	fileprivate var text: SkippedRowText {
		switch self {
		case .newerKind(let kind, let ulid), .newerVersion(let kind, _, let ulid),
			.malformed(let kind, let ulid):
			SkippedRowText(kind: ScrubbedText(scrubbing: kind), ulid: ScrubbedText(scrubbing: ulid))
		}
	}
}

extension ToolFault {
	fileprivate var code: ProblemCode {
		switch self {
		case .saveFailed: ProblemCode("saveFailed")
		case .toolFailed: ProblemCode("toolFailed")
		}
	}
}

extension SnapshotLineKind {
	fileprivate var code: ProblemCode {
		switch self {
		case .profile: ProblemCode("profile")
		case .wellness: ProblemCode("wellness")
		}
	}
}

extension JournalFault {
	fileprivate var code: ProblemCode {
		switch self {
		case .unreadable: ProblemCode("unreadable")
		case .appendFailed: ProblemCode("appendFailed")
		case .rewriteFailed: ProblemCode("rewriteFailed")
		}
	}
}

extension DiagnosticsFileFailure {
	fileprivate var code: ProblemCode {
		switch self {
		case .couldNotWrite: ProblemCode("couldNotWrite")
		case .shareFailed: ProblemCode("shareFailed")
		}
	}
}
