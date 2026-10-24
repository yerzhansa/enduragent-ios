enum PlanToolSchemas {
	static let planSave: JSONValue = .object([
		"type": .string("object"),
		"properties": .object([
			"plan": .object([
				"type": .string("object"),
				"description": .string("The training plan object to save"),
				"properties": .object([
					"name": .object(["type": .string("string")]),
					"primaryGoal": .object(["type": .string("string")]),
					"totalWeeks": .object([
						"type": .string("integer"),
						"exclusiveMinimum": .number(0),
						"maximum": .number(largestSafeInteger),
					]),
					"status": .object(["type": .string("string")]),
				]),
				"required": .array([.string("name")]),
			])
		]),
		"required": .array([.string("plan")]),
	])

	static let planLoad: JSONValue = .object([
		"type": .string("object"),
		"properties": .object([:]),
	])

	static let assessFeasibility: JSONValue = .object([
		"type": .string("object"),
		"properties": .object([
			"currentFtp": ftpRange,
			"targetFtp": .object([
				"type": .string("integer"),
				"minimum": .number(-largestSafeInteger),
				"maximum": .number(largestSafeInteger),
			]),
			"targetWkg": .object(["type": .string("number")]),
			"currentWeightKg": positiveNumber,
			"experienceLevel": choices(ExperienceLevel.self),
		]),
		"required": .array([.string("currentFtp"), .string("experienceLevel")]),
	])

	static let buildPlanSkeleton: JSONValue = .object([
		"type": .string("object"),
		"properties": .object([
			"experienceLevel": choices(ExperienceLevel.self),
			"ftpWatts": ftpRange,
			"weightKg": positiveNumber,
			"volumeTier": choices(VolumeTier.self),
			"scheduleType": choices(ScheduleType.self),
			"availableDays": days,
			"keySessionDay": choices(Weekday.self),
			"sessionsPerWeek": sessionsPerWeek,
			"goalType": choices(GoalType.self),
			"raceType": choices(RaceType.self),
			"raceDate": .object([
				"description": .string("Target race date, YYYY-MM-DD"),
				"type": .string("string"),
				"pattern": .string(#"^\d{4}-\d{2}-\d{2}$"#),
			]),
			"targetTime": .object([
				"description": .string("Goal finish time, e.g. 5:30:00"),
				"type": .string("string"),
			]),
			"generalGoal": .object(["type": .string("string")]),
			"generalGoalTarget": .object(["type": .string("string")]),
		]),
		"required": .array(
			["experienceLevel", "ftpWatts", "volumeTier", "scheduleType", "goalType"].map(
				JSONValue.string)),
	])

	static let getSampleWeek: JSONValue = .object([
		"type": .string("object"),
		"properties": .object([
			"volumeTier": choices(VolumeTier.self),
			"scheduleType": choices(ScheduleType.self),
			"availableDays": days,
			"keySessionDay": choices(Weekday.self),
			"sessionsPerWeek": sessionsPerWeek,
		]),
		"required": .array([.string("volumeTier"), .string("scheduleType")]),
	])

	private static let largestSafeInteger = 9_007_199_254_740_991.0

	private static let ftpRange: JSONValue = .object([
		"type": .string("integer"),
		"minimum": .number(50),
		"maximum": .number(600),
	])

	private static let positiveNumber: JSONValue = .object([
		"type": .string("number"),
		"exclusiveMinimum": .number(0),
	])

	private static let sessionsPerWeek: JSONValue = .object([
		"type": .string("integer"),
		"minimum": .number(3),
		"maximum": .number(6),
	])

	private static let days: JSONValue = .object([
		"type": .string("array"),
		"items": choices(Weekday.self),
	])

	private static func choices<Choice: RawRepresentable & CaseIterable>(_ choices: Choice.Type)
		-> JSONValue where Choice.RawValue == String
	{
		.object([
			"type": .string("string"),
			"enum": .array(Choice.allCases.map { .string($0.rawValue) }),
		])
	}
}
