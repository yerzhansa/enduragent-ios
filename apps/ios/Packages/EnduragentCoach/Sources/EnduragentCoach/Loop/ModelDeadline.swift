import Foundation

struct ModelDeadline: Sendable {
	let ends: Duration
	let perCall: Duration

	func limited(to duration: Duration, uptime: Duration) -> ModelDeadline {
		ModelDeadline(ends: min(ends, uptime + duration), perCall: perCall)
	}

	func checkDeadline(uptime: Duration) throws(TurnBudgetExceeded) {
		if uptime >= ends {
			throw TurnBudgetExceeded(kind: .wallClock)
		}
	}

	func callDeadline(uptime: Duration) -> Duration {
		min(perCall, max(.zero, ends - uptime))
	}
}
