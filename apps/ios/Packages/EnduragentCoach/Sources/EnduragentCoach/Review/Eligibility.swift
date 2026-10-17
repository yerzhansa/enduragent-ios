import Foundation

package enum Ineligibility: Equatable, Sendable {
	case notAWorkout
	case notCoachCreated
	case pastWorkout
	case pastDate(CivilDate)
}

enum Eligibility {
	static func refusal(of event: CalendarEvent, destination: CivilDate?, today: CivilDate)
		-> Ineligibility?
	{
		guard event.category == "WORKOUT" else { return .notAWorkout }
		guard IntervalsPolicy.isCoachOwned(externalId: event.externalId, tags: event.tags) else {
			return .notCoachCreated
		}
		guard String(event.startDateLocal.prefix(10)) >= today.rawValue else {
			return .pastWorkout
		}
		return destination.flatMap { refusal(ofAddOn: $0, today: today) }
	}

	static func refusal(ofAddOn date: CivilDate, today: CivilDate) -> Ineligibility? {
		date < today ? .pastDate(date) : nil
	}
}
