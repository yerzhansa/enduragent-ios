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
	private var proposalInvocations: [Nonce: Int] = [:]
	private var reviewWrites: [Nonce: ReviewWrite] = [:]
	private let reviewGate = Turnstile()
	private var interrupted = false
	private let ladder: RetryLadder

	private struct ReviewWrite {
		let invocation: Int
		let commit: CommittedWrite
	}
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

	package func reviewing(_ run: @Sendable () async -> ReviewOutcome) async -> ReviewOutcome {
		await reviewGate.pass { await run() }
	}

	package func beginReview() -> Bool {
		guard !interrupted else { return false }
		return true
	}

	package func interrupt() -> WriteSummary {
		interrupted = true
		return summary
	}

	package func recordReview(_ proposal: LiveProposal, evidence: CalendarWriteEvidence) {
		guard proposal.cause == .operation(stamp.operation, stamp.attempt), evidence.dispatched
		else { return }
		let pending = reviewWrites[proposal.body.nonce]
		reviewWrites[proposal.body.nonce] = ReviewWrite(
			invocation: pending?.invocation ?? proposalInvocations[proposal.body.nonce] ?? 0,
			commit: CommittedWrite(
				applied: proposal.body.tool,
				verified: pending?.commit.verified == true || evidence.applied))
	}

	package func proposing(
		_ run: @Sendable () async throws -> PendingProposal
	) async throws -> PendingProposal {
		try await reviewGate.passCancellable(cancellation: CancellationError()) {
			if let outcome = savedReviewWorkBeforeInvocation() {
				throw SavedWorkReached(outcome: outcome)
			}
			let proposal = try await run()
			proposalInvocations[proposal.nonce] = attempts
			return proposal
		}
	}

	package func savedWork() async throws(CancellationError) -> SavedWorkOutcome? {
		try await reviewGate.passCancellable(cancellation: CancellationError()) {
			() throws(CancellationError) in ladder.savedWork(committed: written)
		}
	}

	package func savedReviewWork() async throws(CancellationError) -> SavedWorkOutcome? {
		guard proposalInvocations.values.contains(where: { $0 < attempts }) else { return nil }
		return try await reviewGate.passCancellable(cancellation: CancellationError()) {
			() throws(CancellationError) in
			savedReviewWorkBeforeInvocation()
		}
	}

	private func savedReviewWorkBeforeInvocation() -> SavedWorkOutcome? {
		ladder.savedWork(
			committed: reviewWrites.values.filter { $0.invocation < attempts }.map(\.commit))
	}

	package func resolvedWrites() async throws(CancellationError) -> [CommittedWrite] {
		try await reviewGate.passCancellable(cancellation: CancellationError()) {
			() throws(CancellationError) in written
		}
	}

	package var written: [CommittedWrite] {
		commits + reviewWrites.values.map(\.commit)
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
		var unverifiedCalendarWrites = 0
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
				if !commit.verified { unverifiedCalendarWrites += 1 }
			}
		}
		self.init(
			memorySections: memorySections,
			ledgerEvents: ledgerEvents,
			planSaves: planSaves,
			calendarWrites: calendarWrites,
			unverifiedCalendarWrites: unverifiedCalendarWrites
		)
	}
}
