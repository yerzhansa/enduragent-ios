import Foundation

public enum CoachFailure: Sendable, Equatable {
	case model(ModelFailure)
	case local(LocalFailure)
}

public enum ModelFailure: Sendable, Equatable {
	case providerDown(ProviderTrouble)
	case contextOverflow
	case generationFailed(GenerationFault)
	case budgetExhausted(TurnBudgetExceeded.Kind)
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
		case .model(.providerDown), .model(.generationFailed):
			return AthleteNotice(key: Catalog.chatNoticeResponseFailure, vars: [:], action: tryAgain)
		case .model(.contextOverflow), .model(.budgetExhausted):
			return AthleteNotice(key: Catalog.coachErrorUnknown, vars: [:], action: tryAgain)
		case .local(.recordStorage):
			return AthleteNotice(key: Catalog.coachHistoryDiskFull, vars: [:], action: nil)
		}
	}

	package static func notice(
		for interruption: InterruptionCause, saved: WriteSummary, turn: TurnID
	) -> AthleteNotice {
		_ = interruption
		return AthleteNotice(
			key: Catalog.chatNoticeResponseStopped,
			vars: [:],
			action: saved.isEmpty ? .tryAgain(turn) : nil
		)
	}
}
