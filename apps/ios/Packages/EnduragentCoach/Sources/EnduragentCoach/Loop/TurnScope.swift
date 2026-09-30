import Foundation

package struct CommittedWrite: Sendable, Equatable {
	package let tool: ReplayUnsafeToolName
	package let verified: Bool

	package init(tool: ReplayUnsafeToolName, verified: Bool = true) {
		self.tool = tool
		self.verified = verified
	}
}

extension CommittedWrite {
	package init(applied tool: GatedToolName, verified: Bool) {
		switch tool {
		case .intervalsCreateWorkout: self.init(tool: .intervalsCreateWorkout, verified: verified)
		case .intervalsCreateStrengthWorkout:
			self.init(tool: .intervalsCreateStrengthWorkout, verified: verified)
		case .intervalsDeleteWorkout: self.init(tool: .intervalsDeleteWorkout, verified: verified)
		case .intervalsUpdateWorkout: self.init(tool: .intervalsUpdateWorkout, verified: verified)
		case .planSave: self.init(tool: .planSave, verified: verified)
		}
	}
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
	private var reviewWrites: [CommittedWrite] = []
	private let reviewGate = Turnstile()
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

	package func reviewing(_ run: @Sendable () async -> ReviewOutcome) async -> ReviewOutcome {
		await reviewGate.pass { await run() }
	}

	package func recordReview(_ proposal: LiveProposal, outcome: ReviewOutcome) {
		guard proposal.cause == .operation(stamp.operation, stamp.attempt) else { return }
		switch outcome {
		case .applied:
			reviewWrites.append(CommittedWrite(applied: proposal.body.tool, verified: true))
		case .uncertain:
			reviewWrites.append(CommittedWrite(applied: proposal.body.tool, verified: false))
		case .partiallyApplied, .blocked, .storageUnavailable, .staleControl, .canceled,
			.changedSinceReview, .presentationRecorded:
			break
		}
	}

	package func proposing(
		_ run: @Sendable () async throws -> ToolOutcome
	) async throws -> ToolOutcome {
		try await reviewGate.pass {
			if let outcome = RetryLadder.npm.savedWork(committed: reviewWrites) {
				throw SavedWorkReached(outcome: outcome)
			}
			try Task.checkCancellation()
			return try await run()
		}
	}

	package func savedWork(using ladder: RetryLadder) async -> SavedWorkOutcome? {
		await reviewGate.pass { ladder.savedWork(committed: written) }
	}

	package func savedReviewWork() async -> SavedWorkOutcome? {
		await reviewGate.pass { RetryLadder.npm.savedWork(committed: reviewWrites) }
	}

	package var resolvedWrites: [CommittedWrite] {
		get async { await reviewGate.pass { written } }
	}

	package var written: [CommittedWrite] {
		commits + reviewWrites
	}

	package var summary: WriteSummary {
		WriteSummary(written)
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

struct SavedWorkReached: Error {
	let outcome: SavedWorkOutcome
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
