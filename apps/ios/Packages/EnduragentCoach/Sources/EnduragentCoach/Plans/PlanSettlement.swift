import Foundation

enum PlanSettlement: Sendable, Equatable {
	case nothingWaiting
	case leftWaiting(PlanConfirmationID)
	case notPrepared(PlanSaveNotPrepared)

	func counted(in settlement: Settlement) -> Settlement {
		guard case .leftWaiting = self,
			case .interrupted(let partial, .processEnded, let saved) = settlement
		else { return settlement }
		return .interrupted(
			partial: partial, cause: .processEnded,
			saved: WriteSummary(
				memorySections: saved.memorySections, ledgerEvents: saved.ledgerEvents,
				planConfirmations: 1, calendarWrites: saved.calendarWrites,
				unverifiedCalendarWrites: saved.unverifiedCalendarWrites))
	}

	var notPrepared: PlanSaveNotPrepared? {
		guard case .notPrepared(let cause) = self else { return nil }
		return cause
	}
}

package enum PlanSaveNotPrepared: String, Equatable, Sendable {
	case refused
	case notSaved
	case turnDidNotFinish
}
