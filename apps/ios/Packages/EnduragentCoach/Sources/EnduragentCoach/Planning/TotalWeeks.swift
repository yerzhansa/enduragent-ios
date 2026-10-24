extension Planning {
	static func totalWeeks(_ profile: PlanProfile, today: CivilDate) -> Int {
		let goal = profile.goal
		if goal.type == .race, let raceDate = goal.raceDate {
			let weeks = Int((Double(today.days(until: raceDate)) / 7).rounded(.up))
			return max(8, min(24, weeks))
		}
		if goal.type == .race, let raceType = goal.raceType {
			return raceType.defaultWeeks
		}
		return profile.experience.defaultWeeks
	}
}

extension RaceType {
	fileprivate var defaultWeeks: Int {
		switch self {
		case .century, .granFondo: 12
		case .criterium, .timeTrial: 8
		case .other: 10
		}
	}
}

extension ExperienceLevel {
	fileprivate var defaultWeeks: Int {
		switch self {
		case .beginner: 8
		case .intermediate: 12
		case .advanced, .elite: 16
		}
	}
}
