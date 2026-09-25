import Foundation

public struct SectionName: RawRepresentable, Hashable, Sendable {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}

	public static let person = SectionName(rawValue: "person")
	public static let schedule = SectionName(rawValue: "schedule")
	public static let goals = SectionName(rawValue: "goals")
	public static let preferences = SectionName(rawValue: "preferences")
	public static let notes = SectionName(rawValue: "notes")
	public static let medicalHistory = SectionName(rawValue: "medical-history")
	public static let cyclingProfile = SectionName(rawValue: "cycling-profile")
	public static let cyclingEquipment = SectionName(rawValue: "cycling-equipment")
	public static let cyclingHistory = SectionName(rawValue: "cycling-history")

	public var inject: Bool {
		switch rawValue {
		case SectionName.notes.rawValue, SectionName.cyclingEquipment.rawValue,
			SectionName.cyclingHistory.rawValue:
			return false
		default:
			return true
		}
	}

	public static let cyclingEffective: [SectionName] = [
		.person, .schedule, .goals, .preferences, .notes, .medicalHistory,
		.cyclingProfile, .cyclingEquipment, .cyclingHistory,
	]

	public static var declaredNames: Set<String> {
		Set(cyclingEffective.map(\.rawValue))
	}

	public var hint: String {
		switch rawValue {
		case SectionName.person.rawValue:
			return "name, weight, age, available training days"
		case SectionName.schedule.rawValue:
			return "weekly availability, time windows, blackout days"
		case SectionName.goals.rawValue:
			return "target events, race dates, fitness targets"
		case SectionName.preferences.rawValue:
			return "coaching style, communication preferences"
		case SectionName.notes.rawValue:
			return "anything not covered by other sections"
		case SectionName.medicalHistory.rawValue:
			return "chronic conditions, medications, long-term injuries"
		case SectionName.cyclingProfile.rawValue:
			return "FTP, max/resting HR, W/kg, experience level"
		case SectionName.cyclingEquipment.rawValue:
			return "bikes, trainer, power meter, sensors"
		case SectionName.cyclingHistory.rawValue:
			return "cycling injuries, FTP test history, ride recovery patterns"
		default:
			return rawValue
		}
	}

	public var sectionDescription: String {
		switch rawValue {
		case SectionName.person.rawValue:
			return
				"Name, weight (kg), age, available training days per week. "
				+ "Sport-specific physiology (FTP, VDOT, max HR) goes to the sport-prefixed profile section."
		case SectionName.schedule.rawValue:
			return "Weekly training availability, time windows, blackout days"
		case SectionName.goals.rawValue:
			return
				"Target events, race dates, fitness targets, milestones "
				+ "(e.g., 'sub-3:30 century in October', 'reach 280W FTP by Q3')"
		case SectionName.preferences.rawValue:
			return "Coaching style, training environment, communication preferences"
		case SectionName.notes.rawValue:
			return "Anything else important not covered by other sections"
		case SectionName.medicalHistory.rawValue:
			return
				"Chronic conditions, medications, long-term injuries — facts that persist across sports"
		case SectionName.cyclingProfile.rawValue:
			return
				"FTP (watts), max HR, resting HR, W/kg ratio, experience level. "
				+ "Body data lives in `person`; this is cycling-specific physiology."
		case SectionName.cyclingEquipment.rawValue:
			return "Bikes, trainer, power meter, head unit, indoor setup"
		case SectionName.cyclingHistory.rawValue:
			return
				"Cycling-specific injuries (knee, lower back, fit issues), FTP test history, "
				+ "recovery patterns from rides, ride-related sleep/HRV trends. "
				+ "Chronic conditions belong in `medical-history`, not here."
		default:
			return rawValue
		}
	}
}
