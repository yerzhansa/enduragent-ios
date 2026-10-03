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
	case providerConsentRequired
	case notConfigured(AccessMethod)
	case secureStorageLocked
	case secureStorageUnavailable
	case malformedStoredCredential(CredentialSlot)
}

public enum TrainingFailure: Sendable, Equatable {
	case credentialRejected
	case temporarilyUnavailable
	case requestRejected

	init(_ error: any Error) {
		guard let intervals = error as? IntervalsError, let status = intervals.status else {
			self = .temporarilyUnavailable
			return
		}
		switch status {
		case 401, 403: self = .credentialRejected
		case 408, 429: self = .temporarilyUnavailable
		case 400..<500: self = .requestRejected
		default: self = .temporarilyUnavailable
		}
	}
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
	public let unverifiedCalendarWrites: Int

	public init(
		memorySections: Int, ledgerEvents: Int, planSaves: Int, calendarWrites: Int,
		unverifiedCalendarWrites: Int = 0
	) {
		self.memorySections = memorySections
		self.ledgerEvents = ledgerEvents
		self.planSaves = planSaves
		self.calendarWrites = calendarWrites
		self.unverifiedCalendarWrites = unverifiedCalendarWrites
	}

	public static let none = WriteSummary(
		memorySections: 0, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)

	public var isEmpty: Bool {
		memorySections == 0 && ledgerEvents == 0 && planSaves == 0 && calendarWrites == 0
	}
}

public struct AthleteNotice: Sendable, Equatable {
	public let key: CatalogKey
	public let count: Int?
	public let vars: [String: CatalogArgument]
	public let action: RecoveryAction?

	package init(
		key: CatalogKey, count: Int? = nil, vars: [String: CatalogArgument] = [:],
		action: RecoveryAction?
	) {
		self.key = key
		self.count = count
		self.vars = vars
		self.action = action
	}

	package var canonicalSentence: String {
		LanguageTag.en.phrasebook.say(key, count: count, vars.mapValues(\.canonicalText))
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public func sentence(in display: DisplayLocale) -> String {
		display.say(key, count: count, vars).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

public enum RecoveryAction: Sendable, Equatable {
	case tryAgain(TurnID)
	case wait(thenTryAgain: TurnID)
	case restoreCredits
	case buyCredits
	case chooseAccessMethod
	case signInToOpenRouter
	case connectTraining

	public var title: CatalogKey {
		switch self {
		case .tryAgain, .wait: Catalog.chatTranscriptRetry
		case .restoreCredits: Catalog.chatTurnRestorePurchases
		case .buyCredits: Catalog.chatTurnBuyCredits
		case .chooseAccessMethod: Catalog.chatTurnChooseAccessMethod
		case .signInToOpenRouter: Catalog.chatTurnSignInAgain
		case .connectTraining: Catalog.onboardingConnectAction
		}
	}
}

extension CoachFailure {
	package var abandonsFlush: Bool {
		switch self {
		case .model(.credentialRejected), .model(.invalidRequest), .model(.generationFailed),
			.model(.contextOverflow):
			true
		case .model(.accessExhausted), .model(.rateLimited), .model(.providerDown),
			.model(.budgetExhausted), .model(.accessUnavailable), .local:
			false
		}
	}

	package var tryAgainWait: Duration? {
		guard case .model(.rateLimited(let retryAfter)) = self else { return nil }
		return retryAfter.flatMap { $0 > .zero ? $0 : nil } ?? .seconds(60)
	}
}

extension AthleteNotice {
	public static let recordStoreUnavailable = [
		AthleteNotice(key: Catalog.chatHistoryFailure, action: nil),
		AthleteNotice(
			key: Catalog.chatFirstSyncReconnectDetail, vars: ["product": "Enduragent"], action: nil),
	]

	public static func credits(failure: any Error) -> AthleteNotice {
		AthleteNotices.notice(forCredits: failure)
	}
}

extension ReviewOutcome {
	public var notice: AthleteNotice? {
		AthleteNotices.notice(for: self)
	}
}

package enum AthleteNotices {
	private static let openRouter = "OpenRouter"
	private static let intervals = "intervals.icu"
	package static let unrecoveredClaim = AthleteNotice(
		key: Catalog.chatHistoryFailure, action: nil)
	package static let earlierVersion = ReviewNotice(
		kind: .earlierVersion, key: Catalog.reviewEarlierVersion, vars: [:])
	package static let accountChanged = ReviewNotice(
		kind: .accountChanged, key: Catalog.reviewAccountChanged, vars: ["service": intervals])

	package static func notice(for outcome: ReviewOutcome) -> AthleteNotice? {
		switch outcome {
		case .applied, .canceled, .presentationRecorded:
			return nil
		case .partiallyApplied(_, _, let failure):
			return notice(for: failure)
		case .uncertain(let notice), .changedSinceReview(let notice):
			return AthleteNotice(
				key: notice.key, vars: notice.vars.mapValues(CatalogArgument.text), action: nil)
		case .blocked(.accountChanged):
			return AthleteNotice(
				key: accountChanged.key, vars: accountChanged.vars.mapValues(CatalogArgument.text),
				action: nil)
		case .blocked(.trainingNotConnected):
			return AthleteNotice(key: Catalog.connectMissing, action: .connectTraining)
		case .blocked(.cannotVerify):
			return AthleteNotice(
				key: Catalog.reviewCannotVerify, vars: ["service": .text(intervals)], action: nil)
		case .blocked(.turnStopping):
			return AthleteNotice(key: Catalog.reviewTurnStopping, action: nil)
		case .staleControl:
			return AthleteNotice(key: Catalog.coachConfirmationExpired, action: nil)
		case .storageUnavailable:
			return AthleteNotice(key: Catalog.reviewSaveFailed, action: nil)
		case .blocked(.pastProtected), .blocked(.coachOnly), .blocked(.workoutOnly):
			return AthleteNotice(key: Catalog.coachErrorUnknown, action: nil)
		}
	}

	package static func notice(for failure: CoachFailure, turn: TurnID?, waiting: Bool)
		-> AthleteNotice
	{
		let tryAgain = turn.map(RecoveryAction.tryAgain)
		switch failure {
		case .model(.credentialRejected(.credits)):
			return AthleteNotice(key: Catalog.creditsErrorAccessRejected, action: .restoreCredits)
		case .model(.credentialRejected(.openRouterAccount)):
			return AthleteNotice(
				key: Catalog.coachErrorReauth, vars: ["provider": .text(openRouter)],
				action: .signInToOpenRouter)
		case .model(.accessExhausted(.credits)):
			return AthleteNotice(key: Catalog.creditsErrorExhausted, action: .buyCredits)
		case .model(.accessExhausted(.openRouterAccount)):
			return AthleteNotice(
				key: Catalog.accessErrorOpenRouterFunds, action: .chooseAccessMethod)
		case .model(.rateLimited(let retryAfter)):
			let offer = waiting ? RecoveryAction.wait(thenTryAgain:) : RecoveryAction.tryAgain
			return rateLimitNotice(after: retryAfter, action: turn.map(offer))
		case .model(.providerDown):
			return AthleteNotice(key: Catalog.coachErrorProviderDown, action: tryAgain)
		case .model(.contextOverflow), .model(.invalidRequest), .model(.budgetExhausted):
			return AthleteNotice(key: Catalog.coachErrorUnknown, action: tryAgain)
		case .model(.generationFailed):
			return AthleteNotice(key: Catalog.chatNoticeResponseFailure, action: tryAgain)
		case .model(.accessUnavailable(.providerConsentRequired)):
			return AthleteNotice(key: Catalog.accessErrorProviderConsentRequired, action: tryAgain)
		case .model(.accessUnavailable(.secureStorageLocked)):
			return AthleteNotice(key: Catalog.accessErrorLocked, action: tryAgain)
		case .model(.accessUnavailable(.notConfigured)):
			return AthleteNotice(key: Catalog.accessErrorNotConfigured, action: .chooseAccessMethod)
		case .model(.accessUnavailable(.secureStorageUnavailable)):
			return AthleteNotice(
				key: Catalog.accessErrorStorageUnavailable, action: .chooseAccessMethod)
		case .model(.accessUnavailable(.malformedStoredCredential(.intervalsConnection))):
			return AthleteNotice(
				key: Catalog.connectErrorStorageMalformed, action: .connectTraining)
		case .model(.accessUnavailable(.malformedStoredCredential)):
			return AthleteNotice(key: Catalog.accessErrorMalformed, action: .chooseAccessMethod)
		case .local(.recordStorage):
			return AthleteNotice(key: Catalog.coachHistoryDiskFull, action: nil)
		}
	}

	private static func rateLimitNotice(after retryAfter: Duration?, action: RecoveryAction?)
		-> AthleteNotice
	{
		guard let hinted = retryAfter.flatMap({ $0 > .zero ? $0 : nil }),
			let seconds = wholeInt((hinted / .seconds(1)).rounded(.up))
		else {
			return AthleteNotice(key: Catalog.coachErrorRateLimitDefault, action: action)
		}
		if seconds < 60 {
			return AthleteNotice(
				key: Catalog.coachErrorRateLimitSeconds, count: seconds,
				vars: ["seconds": .integer(seconds)],
				action: action
			)
		}
		let minutes = (seconds + 59) / 60
		return AthleteNotice(
			key: Catalog.coachErrorRateLimitMinutes, count: minutes,
			vars: ["minutes": .integer(minutes)],
			action: action
		)
	}

	package static func notice(for status: CoachStatus) -> AthleteNotice? {
		if case .accessTemporarilyUnavailable(let unavailable) = status.setup {
			return notice(outsideTurn: unavailable)
		}
		guard case .connected(let summary, _) = status.training else { return nil }
		return summary.notice
	}

	package static func notice(for training: TrainingFailure) -> AthleteNotice {
		switch training {
		case .credentialRejected, .requestRejected:
			AthleteNotice(
				key: Catalog.coachErrorIntervalsCredentials, vars: ["service": .text(intervals)],
				action: nil)
		case .temporarilyUnavailable:
			AthleteNotice(
				key: Catalog.coachErrorIntervalsTransient, vars: ["service": .text(intervals)],
				action: nil
			)
		}
	}

	package static func notice(forCredits failure: any Error) -> AthleteNotice {
		if let unavailable = failure as? AccessUnavailable {
			return notice(outsideTurn: unavailable)
		}
		switch failure as? CreditsFailure {
		case .noAthleteKey?:
			return notice(outsideTurn: .notConfigured(.credits))
		case .accountChanged?:
			return AthleteNotice(key: Catalog.creditsErrorAccountChanged, action: nil)
		default:
			return AthleteNotice(key: Catalog.creditsErrorUnavailable, action: nil)
		}
	}

	private static func notice(outsideTurn unavailable: AccessUnavailable) -> AthleteNotice {
		let turn = notice(for: .model(.accessUnavailable(unavailable)), turn: nil, waiting: false)
		return AthleteNotice(key: turn.key, count: turn.count, vars: turn.vars, action: nil)
	}

	package static func notice(for outcome: SavedWorkOutcome, saved: WriteSummary = .none)
		-> AthleteNotice
	{
		switch outcome {
		case .writesSaved:
			AthleteNotice(key: Catalog.coachFallbackWritesSaved, action: nil)
		case .savedUnverified:
			AthleteNotice(
				key: saved.calendarWrites > 0
					? Catalog.chatNoticeCalendarUnverified : Catalog.chatNoticeSavedUnverified,
				action: nil)
		}
	}

	package static func notice(
		for interruption: InterruptionCause, saved: WriteSummary, turn: TurnID?
	) -> AthleteNotice {
		if saved.calendarWrites > 0 {
			return AthleteNotice(
				key: saved.unverifiedCalendarWrites > 0
					? Catalog.chatNoticeCalendarUnverified : Catalog.chatTurnInterruptedSomeSaved,
				action: nil)
		}
		switch interruption {
		case .athleteStopped, .systemExpired, .graceEnded, .appTerminating, .processEnded,
			.stoppedBeforeStart:
			return AthleteNotice(
				key: saved.isEmpty
					? Catalog.chatTurnInterruptedNothingChanged
					: Catalog.chatTurnInterruptedSomeSaved,
				action: turn.map(RecoveryAction.tryAgain))
		}
	}
}

public struct TurnBudgetExceeded: Error, Equatable, Sendable {
	public var kind: Kind

	public enum Kind: String, Sendable, Equatable {
		case generateCalls
		case generateAttempts
		case wallClock
	}
}
