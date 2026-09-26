import Foundation

public enum CoachFailure: Sendable, Equatable {
	case model(ModelFailure)
	case local(LocalFailure)
}

public enum ModelFailure: Sendable, Equatable {
	case credentialRejected(AccessMethod)
	case accessExhausted(AccessMethod)
	case rateLimited(retryAfter: Duration?)
	case providerDown(ProviderTrouble)
	case contextOverflow
	case invalidRequest
	case generationFailed(GenerationFault)
	case budgetExhausted(TurnBudgetExceeded.Kind)
	case accessUnavailable(AccessUnavailable)

	package init(_ failure: ProviderFailure, method: AccessMethod) {
		switch failure {
		case .credentialRejected:
			self = .credentialRejected(method)
		case .accessExhausted:
			self = .accessExhausted(method)
		case .rateLimited(let retryAfter):
			self = .rateLimited(retryAfter: retryAfter)
		case .serverError:
			self = .providerDown(.outage)
		case .network:
			self = .providerDown(.network)
		case .timeout:
			self = .providerDown(.timeout)
		case .contextOverflow:
			self = .contextOverflow
		case .invalidRequest:
			self = .invalidRequest
		case .unknownFinish:
			self = .generationFailed(.unknownFinish)
		case .malformedStream:
			self = .generationFailed(.malformedStream)
		}
	}
}

public enum AccessUnavailable: Error, Sendable, Equatable {
	case notConfigured(AccessMethod)
	case secureStorageLocked
	case secureStorageUnavailable
}

public enum ProviderTrouble: String, Sendable {
	case outage
	case network
	case timeout
}

public enum GenerationFault: String, Sendable {
	case emptyAfterError
	case contentFiltered
	case unknownFinish
	case malformedStream
}

public enum LocalFailure: String, Sendable {
	case recordStorage
}

public enum SavedWorkOutcome: String, Sendable {
	case writesSaved
	case savedUnverified
}

public struct WriteSummary: Sendable, Equatable {
	public let memorySections: Int
	public let ledgerEvents: Int
	public let planSaves: Int
	public let calendarWrites: Int

	public init(memorySections: Int, ledgerEvents: Int, planSaves: Int, calendarWrites: Int) {
		self.memorySections = memorySections
		self.ledgerEvents = ledgerEvents
		self.planSaves = planSaves
		self.calendarWrites = calendarWrites
	}

	public static let none = WriteSummary(
		memorySections: 0, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)

	public var isEmpty: Bool {
		memorySections == 0 && ledgerEvents == 0 && planSaves == 0 && calendarWrites == 0
	}
}

public struct AthleteNotice: Sendable, Equatable {
	public let key: CatalogKey
	public let vars: [String: String]
	public let action: RecoveryAction?
}

public enum RecoveryAction: Sendable, Equatable {
	case tryAgain(TurnID)
}

package enum AthleteNotices {
	package static func notice(for failure: CoachFailure, turn: TurnID?, now: Date) -> AthleteNotice
	{
		_ = now
		let tryAgain = turn.map(RecoveryAction.tryAgain)
		switch failure {
		case .model(.credentialRejected):
			return AthleteNotice(key: Catalog.coachErrorProviderCredentials, vars: [:], action: nil)
		case .model(.accessExhausted):
			return AthleteNotice(key: Catalog.coachErrorUnknown, vars: [:], action: nil)
		case .model(.rateLimited(let retryAfter)):
			return rateLimitNotice(after: retryAfter, action: tryAgain)
		case .model(.providerDown):
			return AthleteNotice(key: Catalog.coachErrorProviderDown, vars: [:], action: tryAgain)
		case .model(.generationFailed):
			return AthleteNotice(
				key: Catalog.chatNoticeResponseFailure, vars: [:], action: tryAgain)
		case .model(.contextOverflow), .model(.invalidRequest), .model(.budgetExhausted),
			.model(.accessUnavailable):
			return AthleteNotice(key: Catalog.coachErrorUnknown, vars: [:], action: tryAgain)
		case .local(.recordStorage):
			return AthleteNotice(key: Catalog.coachHistoryDiskFull, vars: [:], action: nil)
		}
	}

	private static func rateLimitNotice(after wait: Duration?, action: RecoveryAction?)
		-> AthleteNotice
	{
		guard let wait, wait > .zero else {
			return AthleteNotice(key: Catalog.coachErrorRateLimitDefault, vars: [:], action: action)
		}
		let seconds = Int((wait / .seconds(1)).rounded(.up))
		if seconds < 60 {
			return AthleteNotice(
				key: Catalog.coachErrorRateLimitSeconds,
				vars: ["count": "\(seconds)", "seconds": "\(seconds)"],
				action: action
			)
		}
		let minutes = (seconds + 59) / 60
		return AthleteNotice(
			key: Catalog.coachErrorRateLimitMinutes,
			vars: ["count": "\(minutes)", "minutes": "\(minutes)"],
			action: action
		)
	}

	package static func notice(for outcome: SavedWorkOutcome) -> AthleteNotice {
		switch outcome {
		case .writesSaved:
			return AthleteNotice(key: Catalog.coachFallbackWritesSaved, vars: [:], action: nil)
		case .savedUnverified:
			return AthleteNotice(key: Catalog.coachErrorUnknown, vars: [:], action: nil)
		}
	}

	package static func notice(
		for interruption: InterruptionCause, turn: TurnID?
	) -> AthleteNotice {
		_ = interruption
		return AthleteNotice(
			key: Catalog.chatNoticeResponseStopped,
			vars: [:],
			action: turn.map(RecoveryAction.tryAgain)
		)
	}
}
