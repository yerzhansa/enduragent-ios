import Foundation

enum MailboxPhase: Sendable {
	case collecting
	case running(RunningWork)
	case stopping(InterruptionCause, RunningWork?)

	var running: RunningWork? {
		switch self {
		case .collecting: nil
		case .running(let running), .stopping(_, let running?): running
		case .stopping(_, nil): nil
		}
	}

	var cause: InterruptionCause? {
		guard case .stopping(let cause, _) = self else { return nil }
		return cause
	}

	func items(in segment: Segment, queued: [MailboxWork]) -> [MailboxWork] {
		guard let running else { return queued }
		if let live = running.live,
			segment.turns.first(where: { $0.turn == live.turn })?.settlements.contains(where: {
				$0.attempt == live.attempt
			}) == true
		{
			return queued
		}
		return [running.item] + queued
	}
}

struct RunningWork: Sendable {
	let item: MailboxWork
	let task: Task<Void, Never>
	var live: LiveAttempt?
}
