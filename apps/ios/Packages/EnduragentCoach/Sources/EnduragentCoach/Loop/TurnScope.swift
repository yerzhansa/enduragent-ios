import Foundation

package struct CommittedWrite: Sendable, Equatable {
	package let tool: ReplayUnsafeToolName
}

package struct ToolExecution: Sendable, Equatable {
	package let outcome: ToolOutcome
	package let commit: CommittedWrite?

	static func result(_ value: JSONValue) -> ToolExecution {
		ToolExecution(outcome: .result(value), commit: nil)
	}
}

package actor TurnScope {
	package nonisolated let stamp: OperationStamp
	package nonisolated let policy: TurnBudgetPolicy
	private let started: Duration
	private var calls = 0
	private var attempts = 0
	private var memo: [MemoKey: Task<ToolExecution, Error>] = [:]
	private var commits: [CommittedWrite] = []
	private var flushLatch = true

	private struct MemoKey: Hashable {
		let tool: ToolName
		let arguments: String
	}

	package init(stamp: OperationStamp, policy: TurnBudgetPolicy, uptime: Duration) {
		self.stamp = stamp
		self.policy = policy
		self.started = uptime
	}

	package func chargeCall() throws(TurnBudgetExceeded) {
		calls += 1
		if calls > policy.maxGenerateCalls {
			throw TurnBudgetExceeded(kind: .generateCalls)
		}
	}

	package func chargeAttempt() throws(TurnBudgetExceeded) {
		attempts += 1
		if attempts > policy.maxGenerateAttempts {
			throw TurnBudgetExceeded(kind: .generateAttempts)
		}
	}

	package func checkDeadline(uptime: Duration) throws(TurnBudgetExceeded) {
		if uptime - started >= policy.wallClock {
			throw TurnBudgetExceeded(kind: .wallClock)
		}
	}

	package func callDeadline(uptime: Duration) -> Duration {
		let remaining = max(.zero, policy.wallClock - (uptime - started))
		return min(policy.perCallDeadline, remaining)
	}

	package var flushLatchFree: Bool {
		flushLatch
	}

	package func takeFlushLatch() -> Bool {
		defer { flushLatch = false }
		return flushLatch
	}

	package func record(_ commit: CommittedWrite) {
		commits.append(commit)
	}

	package var written: [CommittedWrite] {
		commits
	}

	package var summary: WriteSummary {
		WriteSummary(commits)
	}

	package func memoized(
		_ tool: ToolName,
		arguments: String,
		run: @escaping @Sendable () async throws -> ToolExecution
	) async throws -> ToolExecution {
		let key = MemoKey(tool: tool, arguments: arguments)
		if let known = memo[key] {
			return try await known.value
		}
		let task = Task { try await run() }
		memo[key] = task
		do {
			return try await task.value
		} catch {
			memo[key] = nil
			throw error
		}
	}

	package func evict(_ tools: Set<ToolName>) {
		memo = memo.filter { key, _ in !tools.contains(key.tool) }
	}
}

extension WriteSummary {
	package init(_ commits: [CommittedWrite]) {
		var memorySections = 0
		var ledgerEvents = 0
		var planSaves = 0
		var calendarWrites = 0
		for commit in commits {
			switch commit.tool {
			case .memoryWrite:
				memorySections += 1
			case .ledgerAppend:
				ledgerEvents += 1
			case .planSave:
				planSaves += 1
			case .intervalsCreateWorkout, .intervalsCreateStrengthWorkout,
				.intervalsDeleteWorkout, .intervalsUpdateWorkout:
				calendarWrites += 1
			}
		}
		self.init(
			memorySections: memorySections,
			ledgerEvents: ledgerEvents,
			planSaves: planSaves,
			calendarWrites: calendarWrites
		)
	}
}
