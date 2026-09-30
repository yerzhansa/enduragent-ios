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

	func active(in segment: Segment) -> MailboxWork? {
		guard let running else { return nil }
		if let live = running.live,
			segment.turns.first(where: { $0.turn == live.turn })?.settlements.contains(where: {
				$0.attempt == live.attempt
			}) == true
		{
			return nil
		}
		return running.item
	}

	func overlay(
		of turn: TurnID, in segment: Segment, window: OpenWindow?, queued: [MailboxWork],
		waiting: Set<TurnID>
	) -> TurnOverlay {
		let items = [active(in: segment)].compactMap { $0 } + queued
		return TurnOverlay(
			of: turn, window: window, queued: items.compactMap(\.turn), waiting: waiting)
	}
}

struct RunningWork: Sendable {
	let item: MailboxWork
	let task: Task<Void, Never>
	var live: LiveAttempt?
}
