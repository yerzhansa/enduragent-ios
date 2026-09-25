import Foundation

package struct TurnState: Sendable, Equatable {
	package var chatId: ChatID
	package var messages: [ChatMessage]
	package var windowStart: ULID?
	package var pending: ProposalBody?
	package var writesCommitted: Int
	package var flushedThisTurn: Bool
	package var lastFlushMessageCount: Int
	package var steps: Int
}

public enum TurnPolicy {
	public static let maxSteps = 10
	public static let maxGenerateCalls = 40
	public static let maxAttempts = 4
	public static let wallClock: Duration = .seconds(10 * 60)
	public static let chatCallDeadline: Duration = .seconds(600)
	public static let compactionTimeout: Duration = .seconds(120)
	public static let toolResultTokenCap = 24_000
	public static let athleteContextChars = 20_000
	public static let historyBudgetFloor = 8_000
	public static let historyTokenBudgetRatio = 0.3
	public static let contextWindowCap = 200_000
	public static let overflowRetries = 3
	public static let dailyResetHour = 4
	public static let dailyResetGrace: Duration = .seconds(30 * 60)
	public static let proposalTTL: Duration = .seconds(10 * 60)
	public static let ungatedPrefixTokenCeiling = 13_200
	public static let gatedPrefixTokenCeiling = 13_600
}

public struct TurnBudgetExceeded: Error, Equatable, Sendable {
	public var kind: Kind

	public enum Kind: Sendable, Equatable {
		case generateCalls
		case generateAttempts
		case wallClock
	}
}

public struct TurnBudget: Sendable {
	public var generatesRemaining: Int
	public var attemptsRemaining: Int
	public var deadline: ContinuousClock.Instant

	public static func start(clock: ContinuousClock = ContinuousClock()) -> TurnBudget {
		TurnBudget(
			generatesRemaining: TurnPolicy.maxGenerateCalls,
			attemptsRemaining: TurnPolicy.maxAttempts,
			deadline: clock.now.advanced(by: TurnPolicy.wallClock)
		)
	}

	public mutating func chargeGenerate() throws {
		guard generatesRemaining > 0 else {
			throw TurnBudgetExceeded(kind: .generateCalls)
		}
		generatesRemaining -= 1
	}

	public mutating func chargeAttempt() throws {
		guard attemptsRemaining > 0 else {
			throw TurnBudgetExceeded(kind: .generateAttempts)
		}
		attemptsRemaining -= 1
	}

	public func remaining(until now: ContinuousClock.Instant) -> Duration {
		now < deadline ? deadline - now : .zero
	}

	public func checkDeadline(now: ContinuousClock.Instant = ContinuousClock().now) throws {
		if now >= deadline {
			throw TurnBudgetExceeded(kind: .wallClock)
		}
	}
}
