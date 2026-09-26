import Foundation

package struct TurnBudgetPolicy: Sendable, Equatable {
	package let maxGenerateAttempts: Int
	package let maxGenerateCalls: Int
	package let wallClock: Duration
	package let maxStepsPerInvocation: Int
	package let perCallDeadline: Duration

	package static let npm = TurnBudgetPolicy(
		maxGenerateAttempts: 4,
		maxGenerateCalls: 40,
		wallClock: .seconds(10 * 60),
		maxStepsPerInvocation: 10,
		perCallDeadline: .seconds(600)
	)
}

public struct TurnBudgetExceeded: Error, Equatable, Sendable {
	public var kind: Kind

	public enum Kind: String, Sendable, Equatable {
		case generateCalls
		case generateAttempts
		case wallClock
	}
}

package enum LadderClass: Hashable, Sendable {
	case overflow
	case timeout
	case rateLimit
	case serverError
	case network
	case auth
	case invalidRequest
	case unknown
}

package enum LadderCounter: Hashable, Sendable {
	case overflow
	case timeout
	case plainTimeout
	case rateLimit
	case serverOrNetwork
}

package enum LadderGuard: Sendable, Equatable {
	case budgetExceededIsTerminal
	case committedWriteSettlesAsSavedWork(
		calendar: Set<ReplayUnsafeToolName>, other: Set<ReplayUnsafeToolName>)
	case observedTextIsTerminalUnlessWindowExceeded
}

package enum WaitRule: Sendable, Equatable {
	case retryAfterOrExponential(
		base: Duration, multiplier: Int, fallbackCap: Duration, ceiling: Duration)
	case jittered(base: Duration, cap: Duration, hintSpread: Duration)
}

package enum RungRecovery: Sendable, Equatable {
	case flushOnceThenCompact(trigger: FlushTrigger)
	case compactAboveRatio(ratio: Double, reserveTokens: Int, plainLimit: Int)
	case wait(WaitRule, RetryWaitReason)
}

package struct LadderRung: Sendable, Equatable {
	package let classes: Set<LadderClass>
	package let counter: LadderCounter
	package let limit: Int
	package let recovery: RungRecovery
}

package struct RetryLadder: Sendable, Equatable {
	package let guards: [LadderGuard]
	package let rungs: [LadderRung]

	package static let npm = RetryLadder(
		guards: [
			.budgetExceededIsTerminal,
			.committedWriteSettlesAsSavedWork(
				calendar: [
					.intervalsCreateWorkout,
					.intervalsCreateStrengthWorkout,
					.intervalsDeleteWorkout,
					.intervalsUpdateWorkout,
				],
				other: [.memoryWrite, .ledgerAppend, .planSave]
			),
			.observedTextIsTerminalUnlessWindowExceeded,
		],
		rungs: [
			LadderRung(
				classes: [.overflow],
				counter: .overflow,
				limit: 3,
				recovery: .flushOnceThenCompact(trigger: .overflow)
			),
			LadderRung(
				classes: [.timeout],
				counter: .timeout,
				limit: 2,
				recovery: .compactAboveRatio(
					ratio: 0.65, reserveTokens: TurnPolicy.reserveTokens, plainLimit: 1)
			),
			LadderRung(
				classes: [.rateLimit],
				counter: .rateLimit,
				limit: 3,
				recovery: .wait(
					.retryAfterOrExponential(
						base: .seconds(5),
						multiplier: 2,
						fallbackCap: .seconds(30),
						ceiling: .seconds(120)
					),
					.rateLimited
				)
			),
			LadderRung(
				classes: [.serverError, .network],
				counter: .serverOrNetwork,
				limit: 2,
				recovery: .wait(
					.jittered(base: .milliseconds(500), cap: .seconds(5), hintSpread: .seconds(1)),
					.providerTrouble
				)
			),
		]
	)

	package func decide(
		_ failure: AttemptFailure,
		situation: AttemptSituation,
		counters: RetryCounters
	) -> LadderDecision {
		for rule in guards {
			if let decision = rule.decision(for: failure, in: situation) {
				return decision
			}
		}
		let failureClass = failure.ladderClass
		for rung in rungs
		where rung.classes.contains(failureClass) && counters.count(rung.counter) < rung.limit {
			if let retry = rung.retry(after: failure, in: situation, counters: counters) {
				return retry
			}
		}
		return .terminal(failure.coachFailure(for: situation.accessMethod))
	}
}

package enum AttemptFailure: Error, Sendable, Equatable {
	case budget(TurnBudgetExceeded)
	case provider(ProviderFailure)
	case windowExceededFinish
	case generation(GenerationFault)
	case recordStorage
	indirect case rescueFailed(AttemptFailure)

	package init(caught error: any Error) throws(CancellationError) {
		switch error {
		case is CancellationError:
			throw CancellationError()
		case let failure as AttemptFailure:
			self = failure
		case let exceeded as TurnBudgetExceeded:
			self = .budget(exceeded)
		case let failure as ProviderFailure:
			self = .provider(failure)
		case is LedgerFailure:
			self = .recordStorage
		default:
			self = .generation(.malformedStream)
		}
	}

	package func coachFailure(for method: AccessMethod) -> CoachFailure {
		switch self {
		case .budget(let exceeded):
			.model(.budgetExhausted(exceeded.kind))
		case .provider(let failure):
			.model(ModelFailure(failure, method: method))
		case .windowExceededFinish:
			.model(.contextOverflow)
		case .generation(let fault):
			.model(.generationFailed(fault))
		case .recordStorage:
			.local(.recordStorage)
		case .rescueFailed(let original):
			original.coachFailure(for: method)
		}
	}

	fileprivate var ladderClass: LadderClass {
		switch self {
		case .provider(.contextOverflow), .windowExceededFinish:
			.overflow
		case .provider(.timeout):
			.timeout
		case .provider(.rateLimited):
			.rateLimit
		case .provider(.serverError):
			.serverError
		case .provider(.network):
			.network
		case .provider(.credentialRejected):
			.auth
		case .provider(.invalidRequest):
			.invalidRequest
		case .provider(.accessExhausted), .provider(.unknownFinish), .provider(.malformedStream),
			.budget, .generation, .recordStorage, .rescueFailed:
			.unknown
		}
	}

	fileprivate var retryAfter: Duration? {
		switch self {
		case .provider(.rateLimited(let hint)), .provider(.serverError(_, let hint)):
			hint
		default:
			nil
		}
	}
}

package struct AttemptSituation: Sendable, Equatable {
	package let committed: [CommittedWrite]
	package let observedText: Bool
	package let promptTokens: Int
	package let effectiveWindow: Int
	package let flushLatchFree: Bool
	package let accessMethod: AccessMethod
	package let jitter: Double
}

package struct RetryCounters: Sendable, Equatable {
	package private(set) var used: [LadderCounter: Int]

	package static let zero = RetryCounters(used: [:])

	package func count(_ counter: LadderCounter) -> Int {
		used[counter] ?? 0
	}

	package func incremented(_ counters: Set<LadderCounter>) -> RetryCounters {
		var next = self
		for counter in counters {
			next.used[counter, default: 0] += 1
		}
		return next
	}
}

package enum LadderDecision: Sendable, Equatable {
	case terminal(CoachFailure)
	case settleSavedWork(SavedWorkOutcome)
	case retry(counters: RetryCounters, preparations: [RetryPreparation])
}

package enum RetryPreparation: Sendable, Equatable {
	case flushMemory(FlushTrigger)
	case compactInTurn
	case wait(Duration, RetryWaitReason)
}

extension LadderGuard {
	fileprivate func decision(for failure: AttemptFailure, in situation: AttemptSituation)
		-> LadderDecision?
	{
		switch self {
		case .budgetExceededIsTerminal:
			guard case .budget = failure else { return nil }
			return .terminal(failure.coachFailure(for: situation.accessMethod))
		case .committedWriteSettlesAsSavedWork(let calendar, let other):
			let tools = Set(situation.committed.map(\.tool))
			if !tools.isDisjoint(with: calendar) {
				return .settleSavedWork(.writesSaved)
			}
			if !tools.isDisjoint(with: other) {
				return .settleSavedWork(.savedUnverified)
			}
			return nil
		case .observedTextIsTerminalUnlessWindowExceeded:
			guard situation.observedText, failure != .windowExceededFinish else { return nil }
			return .terminal(failure.coachFailure(for: situation.accessMethod))
		}
	}
}

extension LadderRung {
	fileprivate func retry(
		after failure: AttemptFailure, in situation: AttemptSituation, counters: RetryCounters
	) -> LadderDecision? {
		switch recovery {
		case .flushOnceThenCompact(let trigger):
			let flush: [RetryPreparation] = situation.flushLatchFree ? [.flushMemory(trigger)] : []
			return .retry(
				counters: counters.incremented([counter]), preparations: flush + [.compactInTurn])
		case .compactAboveRatio(let ratio, let reserveTokens, let plainLimit):
			let usable = max(situation.effectiveWindow - reserveTokens, 1)
			if Double(situation.promptTokens) / Double(usable) > ratio {
				return .retry(
					counters: counters.incremented([counter]), preparations: [.compactInTurn])
			}
			guard counters.count(.plainTimeout) < plainLimit else { return nil }
			return .retry(
				counters: counters.incremented([counter, .plainTimeout]), preparations: [])
		case .wait(let rule, let reason):
			let wait = rule.duration(
				retry: counters.count(counter) + 1, hint: failure.retryAfter,
				jitter: situation.jitter)
			return .retry(
				counters: counters.incremented([counter]), preparations: [.wait(wait, reason)])
		}
	}
}

extension WaitRule {
	fileprivate func duration(retry: Int, hint: Duration?, jitter: Double) -> Duration {
		switch self {
		case .retryAfterOrExponential(let base, let multiplier, let fallbackCap, let ceiling):
			let growth = (1..<max(retry, 1)).reduce(1) { product, _ in product * multiplier }
			return min(hint ?? min(base * growth, fallbackCap), ceiling)
		case .jittered(let base, let cap, let hintSpread):
			guard let hint else { return min(base, cap) * jitter }
			return min(hint + hintSpread * jitter, cap)
		}
	}
}
