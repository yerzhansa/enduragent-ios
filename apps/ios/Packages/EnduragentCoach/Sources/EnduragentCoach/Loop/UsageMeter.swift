import Foundation
import Synchronization

package final class UsageMeter: Sendable {
	private let tally = Mutex(UsageTally())
	private let started: Duration

	package init(started: Duration) {
		self.started = started
	}

	func add(_ usage: Usage) {
		tally.withLock { $0.add(usage) }
	}

	func addFailure() {
		tally.withLock { $0.failedCalls += 1 }
	}

	func line(origin: UsageOrigin, model: ModelRef, at uptime: Duration) -> UsageLine {
		let spent = tally.withLock { $0 }
		return UsageLine(
			origin: origin, model: model, calls: spent.calls, failedCalls: spent.failedCalls,
			inputTokens: spent.inputTokens, outputTokens: spent.outputTokens,
			cost: spent.cost.flatMap { $0.isFinite ? UsageCost.reported($0) : nil }
				?? .unreported,
			durationMilliseconds: Int(((uptime - started) / .milliseconds(1)).rounded()))
	}
}

struct UsageTally: Sendable {
	var calls = 0
	var failedCalls = 0
	var inputTokens = 0
	var outputTokens = 0
	var cost: Double? = 0

	mutating func add(_ usage: Usage) {
		calls += 1
		inputTokens += usage.inputTokens
		outputTokens += usage.outputTokens
		cost = usage.cost.flatMap { reported in cost.map { $0 + reported } }
	}
}

extension DiagnosticsLog {
	func recordUsage(of meter: UsageMeter, origin: UsageOrigin, model: ModelID, at uptime: Duration)
	{
		guard let model = ModelRef(model) else {
			return recordUnwritableLine()
		}
		recordUsage(meter.line(origin: origin, model: model, at: uptime))
	}
}
