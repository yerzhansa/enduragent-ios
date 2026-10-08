import Foundation

public enum ResetAdmission: Sendable, Equatable {
	case accepted(ResetID)
	case notStarted(CoachFailure)
}

public enum ResetStatus: Sendable, Equatable {
	case idle
	case waiting(ResetID)
	case failed(ResetID, failure: CoachFailure)
}

package enum ResetExecutionOutcome: Sendable, Equatable {
	case started(memory: MemorySaveResult)
	case notStarted(CoachFailure)
}

public enum MemorySaveResult: Sendable, Equatable {
	case providerConsentRequired
	case saved
	case partiallySaved
	case notSaved

	init(_ outcome: FlushOutcome?) {
		switch outcome {
		case .saved, .nothingToSave: self = .saved
		case .partial: self = .partiallySaved
		case .failed(.model(.accessUnavailable(.providerConsentRequired))):
			self = .providerConsentRequired
		case .failed, nil: self = .notSaved
		}
	}
}

private enum ResetProgress {
	case idle
	case waiting(ReservedReset)
	case started(ResetID, memory: MemorySaveResult)
	case failed(ReservedReset, failure: CoachFailure)

	var status: ResetStatus {
		switch self {
		case .idle, .started: .idle
		case .waiting(let reset): .waiting(reset.id)
		case .failed(let reset, let failure): .failed(reset.id, failure: failure)
		}
	}
}

final class MailboxResets {
	private let work: ConversationReset
	private var progress = ResetProgress.idle

	init(_ work: ConversationReset) { self.work = work }

	var status: ResetStatus { progress.status }

	func admit(_ reset: ReservedReset) { progress = .waiting(reset) }

	func memory(for reset: ResetID) -> MemorySaveResult? {
		guard case .started(let current, let memory) = progress, current == reset else {
			return nil
		}
		return memory
	}

	func reconcile(_ conversation: Conversation) {
		switch progress {
		case .waiting(let reset), .failed(let reset, _):
			if let boundary = conversation.current.boundary,
				!boundary.precedes(.observed(reset.boundary))
			{
				progress = .idle
			}
		case .started(let reset, _):
			if conversation.current.openedBy != .reset(reset) { progress = .idle }
		case .idle:
			break
		}
	}

	func run(
		_ reset: ReservedReset, on records: ChatRecords,
		access: @Sendable () async throws(AccessUnavailable) -> ResolvedAccess,
		isolation: isolated (any Actor)? = #isolation, then publish: () -> Void
	) async {
		_ = await records.refreshJobs(from: work.flushes)
		let result = await work.run(
			reset, archiving: records.conversation, jobs: records.jobs, access: access)
		records.apply(result.boundary)
		if case .waiting(let current) = progress, current.id == reset.id {
			switch result.outcome {
			case .started(let memory): progress = .started(reset.id, memory: memory)
			case .notStarted(let failure): progress = .failed(reset, failure: failure)
			}
		}
		publish()
		_ = await records.refreshJobs(from: work.flushes)
		publish()
	}
}
