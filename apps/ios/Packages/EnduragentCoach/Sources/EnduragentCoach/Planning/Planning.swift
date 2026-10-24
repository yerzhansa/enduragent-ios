enum Planning {}

enum ExperienceLevel: String, Sendable, CaseIterable {
	case beginner, intermediate, advanced, elite
}

enum VolumeTier: String, Sendable, CaseIterable {
	case low, medium, high
}

enum ScheduleType: String, Sendable, CaseIterable {
	case fixed, flexible
}

enum RaceType: String, Sendable, CaseIterable {
	case century
	case granFondo = "gran_fondo"
	case criterium
	case timeTrial = "time_trial"
	case other
}

enum GoalType: String, Sendable, CaseIterable {
	case race, general
}
