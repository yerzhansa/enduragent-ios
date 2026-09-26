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

	package init(key: CatalogKey, vars: [String: String] = [:], action: RecoveryAction?) {
		self.key = key
		self.vars = vars
		self.action = action
	}

	public func sentence(in phrasebook: any Phrasebook) -> String {
		phrasebook.say(key, vars).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

public enum RecoveryAction: Sendable, Equatable {
	case tryAgain(TurnID)
	case wait(until: Date, thenTryAgain: TurnID)
	case restoreCredits
	case buyCredits
	case chooseAccessMethod
	case signInToOpenRouter

	public var title: CatalogKey {
		switch self {
		case .tryAgain, .wait: Catalog.chatTranscriptRetry
		case .restoreCredits: Catalog.chatTurnRestorePurchases
		case .buyCredits: Catalog.chatTurnBuyCredits
		case .chooseAccessMethod: Catalog.chatTurnChooseAccessMethod
		case .signInToOpenRouter: Catalog.chatTurnSignInAgain
		}
	}

	public var opensAt: Date? {
		guard case .wait(let until, _) = self else { return nil }
		return until
	}
}

package enum AthleteNotices {
	private static let openRouter = "OpenRouter"
	private static let defaultRateLimitWait: Duration = .seconds(60)

	package static func notice(for failure: CoachFailure, turn: TurnID?, failedAt: Date)
		-> AthleteNotice
	{
		let tryAgain = turn.map(RecoveryAction.tryAgain)
		switch failure {
		case .model(.credentialRejected(.credits)):
			return AthleteNotice(key: Catalog.creditsErrorAccessRejected, action: .restoreCredits)
		case .model(.credentialRejected(.openRouterAccount)):
			return AthleteNotice(
				key: Catalog.coachErrorReauth, vars: ["provider": openRouter],
				action: .signInToOpenRouter)
		case .model(.accessExhausted(.credits)):
			return AthleteNotice(key: Catalog.creditsErrorExhausted, action: .buyCredits)
		case .model(.accessExhausted(.openRouterAccount)):
			return AthleteNotice(
				key: Catalog.accessErrorOpenRouterFunds, action: .chooseAccessMethod)
		case .model(.rateLimited(let retryAfter)):
			return rateLimitNotice(after: retryAfter, turn: turn, failedAt: failedAt)
		case .model(.providerDown):
			return AthleteNotice(key: Catalog.coachErrorProviderDown, action: tryAgain)
		case .model(.contextOverflow), .model(.invalidRequest), .model(.budgetExhausted):
			return AthleteNotice(key: Catalog.coachErrorUnknown, action: tryAgain)
		case .model(.generationFailed):
			return AthleteNotice(key: Catalog.chatNoticeResponseFailure, action: tryAgain)
		case .model(.accessUnavailable(.secureStorageLocked)):
			return AthleteNotice(key: Catalog.accessErrorLocked, action: tryAgain)
		case .model(.accessUnavailable(.notConfigured)),
			.model(.accessUnavailable(.secureStorageUnavailable)):
			return AthleteNotice(key: Catalog.accessErrorNotConfigured, action: .chooseAccessMethod)
		case .local(.recordStorage):
			return AthleteNotice(key: Catalog.coachHistoryDiskFull, action: nil)
		}
	}

	private static func rateLimitNotice(after retryAfter: Duration?, turn: TurnID?, failedAt: Date)
		-> AthleteNotice
	{
		let hinted = retryAfter.flatMap { $0 > .zero ? $0 : nil }
		let opensAt = failedAt.addingTimeInterval((hinted ?? defaultRateLimitWait).timeInterval)
		let action = turn.map { RecoveryAction.wait(until: opensAt, thenTryAgain: $0) }
		guard let hinted else {
			return AthleteNotice(key: Catalog.coachErrorRateLimitDefault, action: action)
		}
		let seconds = Int((hinted / .seconds(1)).rounded(.up))
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
			AthleteNotice(key: Catalog.coachFallbackWritesSaved, action: nil)
		case .savedUnverified:
			AthleteNotice(key: Catalog.chatNoticeSavedUnverified, action: nil)
		}
	}

	package static func notice(
		for interruption: InterruptionCause, saved: WriteSummary, turn: TurnID?
	) -> AthleteNotice {
		switch interruption {
		case .athleteStopped, .appTerminating, .processEnded, .stoppedBeforeStart:
			return AthleteNotice(
				key: saved.isEmpty
					? Catalog.chatTurnInterruptedNothingChanged
					: Catalog.chatTurnInterruptedSomeSaved,
				action: turn.map(RecoveryAction.tryAgain))
		}
	}
}
