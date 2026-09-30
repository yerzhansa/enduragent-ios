import Foundation

enum MailboxPhase: Sendable {
	case idle
	case running(RunningWork)
	case stopping(InterruptionCause, RunningWork?)

	var running: RunningWork? {
		switch self {
		case .idle: nil
		case .running(let running), .stopping(_, let running?): running
		case .stopping(_, nil): nil
		}
	}

	var cause: InterruptionCause? {
		guard case .stopping(let cause, _) = self else { return nil }
		return cause
	}

	func items(queued: [MailboxWork]) -> [MailboxWork] {
		guard let item = running?.item else { return queued }
		return [item] + queued
	}
}

enum RunningWork: Sendable {
	case active(MailboxWork, Task<Void, Never>, LiveAttempt?)
	case finishing(Task<Void, Never>)

	var item: MailboxWork? {
		guard case .active(let item, _, _) = self else { return nil }
		return item
	}

	var task: Task<Void, Never> {
		switch self {
		case .active(_, let task, _), .finishing(let task): task
		}
	}

	var live: LiveAttempt? {
		guard case .active(_, _, let live) = self else { return nil }
		return live
	}
}
