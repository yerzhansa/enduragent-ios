import Foundation

package struct CommittedWrite: Sendable, Equatable {
	package let tool: ReplayUnsafeToolName

	package init(tool: ReplayUnsafeToolName) {
		self.tool = tool
	}
}

package struct ToolExecution: Sendable, Equatable {
	package let outcome: ToolOutcome
	package let commit: CommittedWrite?
	let overCap: JSONValue?

	init(outcome: ToolOutcome, commit: CommittedWrite?, overCap: JSONValue? = nil) {
		self.outcome = outcome
		self.commit = commit
		self.overCap = overCap
	}

	static func result(_ value: JSONValue, overCap: JSONValue? = nil) -> ToolExecution {
		ToolExecution(outcome: .result(value), commit: nil, overCap: overCap)
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
	private let ladder: RetryLadder
	private var flushLatch = true

	private struct MemoKey: Hashable {
		let tool: ToolName
		let arguments: String
	}

	package init(
		stamp: OperationStamp, policy: TurnBudgetPolicy, ladder: RetryLadder, uptime: Duration
	) {
		self.stamp = stamp
		self.policy = policy
		self.ladder = ladder
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

	package func interrupt() -> WriteSummary {
		summary
	}

	package func savedWork() -> SavedWorkOutcome? {
		ladder.savedWork(committed: commits)
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
		let task: Task<ToolExecution, Error>
		if let known = memo[key] {
			task = known
		} else {
			task = Task { try await run() }
		}
		memo[key] = task
		do {
			return try await withTaskCancellationHandler {
				try await task.value
			} onCancel: {
				task.cancel()
			}
		} catch {
			if memo[key] == task { memo[key] = nil }
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
		for commit in commits {
			switch commit.tool {
			case .memoryWrite:
				memorySections += 1
			case .ledgerAppend:
				ledgerEvents += 1
			}
		}
		self.init(
			memorySections: memorySections,
			ledgerEvents: ledgerEvents,
			planConfirmations: 0,
			calendarWrites: 0,
			unverifiedCalendarWrites: 0
		)
	}
}
