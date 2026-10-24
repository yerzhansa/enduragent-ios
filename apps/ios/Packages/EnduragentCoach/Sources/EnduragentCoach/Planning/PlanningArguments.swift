enum PlanningArguments {
	static func feasibility(_ arguments: JSONValue) throws(ToolInputError) -> FeasibilityGoal {
		let fields = try object(arguments)
		guard let currentFtp = try integer(fields, "currentFtp"),
			IntervalsPolicy.ftpRange.contains(currentFtp)
		else {
			throw refusal("currentFtp must be a whole number of watts from 50 to 600.")
		}
		return FeasibilityGoal(
			currentFtp: currentFtp,
			targetFtp: try integer(fields, "targetFtp"),
			targetWkg: try number(fields, "targetWkg"),
			currentWeightKg: try positive(fields, "currentWeightKg"),
			experience: try required(fields, "experienceLevel", ExperienceLevel.self))
	}

	static func profile(_ arguments: JSONValue) throws(ToolInputError) -> PlanProfile {
		let fields = try object(arguments)
		let experience = try required(fields, "experienceLevel", ExperienceLevel.self)
		guard let ftpWatts = try integer(fields, "ftpWatts"),
			IntervalsPolicy.ftpRange.contains(ftpWatts)
		else {
			throw refusal("ftpWatts must be a whole number of watts from 50 to 600.")
		}
		let sessionsPerWeek = try integer(fields, "sessionsPerWeek")
		if let sessionsPerWeek, !(3...6).contains(sessionsPerWeek) {
			throw refusal("sessionsPerWeek must be a whole number from 3 to 6 when given.")
		}
		let schedule = ScheduleInput(
			type: try required(fields, "scheduleType", ScheduleType.self),
			availableDays: try list(fields, "availableDays", Weekday.self),
			keySessionDay: try optional(fields, "keySessionDay", Weekday.self),
			sessionsPerWeek: sessionsPerWeek)
		let weightKg = try positive(fields, "weightKg")
		let volumeTier = try required(fields, "volumeTier", VolumeTier.self)
		let goalType = try required(fields, "goalType", GoalType.self)
		let raceType = try optional(fields, "raceType", RaceType.self)
		let raceKey = try dateKey(fields, "raceDate")
		let targetTime = try string(fields, "targetTime")
		let generalGoal = try string(fields, "generalGoal")
		let generalGoalTarget = try string(fields, "generalGoalTarget")
		return PlanProfile(
			experience: experience, ftpWatts: ftpWatts, weightKg: weightKg,
			volumeTier: volumeTier, schedule: schedule,
			goal: GoalInput(
				type: goalType, raceType: raceType, raceDate: try raceKey.map(realDay),
				targetTime: targetTime, generalGoal: generalGoal,
				generalGoalTarget: generalGoalTarget))
	}

	private static let largestSafeInteger = 9_007_199_254_740_991.0

	static func object(_ arguments: JSONValue) throws(ToolInputError)
		-> [String: JSONValue]
	{
		guard case .object(let fields) = arguments else {
			throw refusal("The arguments must be an object.")
		}
		return fields
	}

	private static func number(_ fields: [String: JSONValue], _ key: String)
		throws(ToolInputError) -> Double?
	{
		guard let value = fields[key] else { return nil }
		guard case .number(let number) = value, number.isFinite else {
			throw refusal("\(key) must be a number when given.")
		}
		return number
	}

	private static func integer(_ fields: [String: JSONValue], _ key: String)
		throws(ToolInputError) -> Int?
	{
		guard let number = try number(fields, key) else { return nil }
		guard number.magnitude <= largestSafeInteger, let whole = Int(exactly: number) else {
			throw refusal("\(key) must be a whole number when given.")
		}
		return whole
	}

	private static func positive(_ fields: [String: JSONValue], _ key: String)
		throws(ToolInputError) -> Double?
	{
		guard let number = try number(fields, key) else { return nil }
		guard number > 0 else { throw refusal("\(key) must be above 0 when given.") }
		return number
	}

	private static func string(_ fields: [String: JSONValue], _ key: String)
		throws(ToolInputError) -> String?
	{
		guard let value = fields[key] else { return nil }
		guard let text = value.stringValue else {
			throw refusal("\(key) must be text when given.")
		}
		return text
	}

	private static func dateKey(_ fields: [String: JSONValue], _ key: String)
		throws(ToolInputError) -> String?
	{
		guard let raw = try string(fields, key) else { return nil }
		let bytes = Array(raw.utf8)
		let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
		guard bytes.count == 10,
			bytes.indices.allSatisfy({ index in
				index == 4 || index == 7
					? bytes[index] == UInt8(ascii: "-") : digits.contains(bytes[index])
			})
		else {
			throw refusal("\(key) must be a date written YYYY-MM-DD when given.")
		}
		return raw
	}

	private static func realDay(_ raw: String) throws(ToolInputError) -> CivilDate {
		guard let day = CivilDate(rawValue: raw) else {
			throw ToolInputError(
				code: "invalid_date",
				details: "\(raw) is not a real calendar date. Use YYYY-MM-DD.")
		}
		return day
	}

	private static func required<Choice: RawRepresentable & CaseIterable>(
		_ fields: [String: JSONValue], _ key: String, _ choices: Choice.Type
	) throws(ToolInputError) -> Choice where Choice.RawValue == String {
		guard let raw = fields[key]?.stringValue, let choice = Choice(rawValue: raw) else {
			let names = Choice.allCases.map(\.rawValue).joined(separator: ", ")
			throw refusal("\(key) must be one of \(names).")
		}
		return choice
	}

	private static func refusal(_ details: String) -> ToolInputError {
		ToolInputError(code: "invalid_input", details: details)
	}

	static func sampleWeek(_ arguments: JSONValue) throws(ToolInputError) -> SampleWeekRequest {
		let fields = try object(arguments)
		let tier = try required(fields, "volumeTier", VolumeTier.self)
		let scheduleType = try required(fields, "scheduleType", ScheduleType.self)
		let availableDays = try list(fields, "availableDays", Weekday.self)
		let keySessionDay = try optional(fields, "keySessionDay", Weekday.self)
		let sessionsPerWeek = try integer(fields, "sessionsPerWeek")
		if let sessionsPerWeek, !(3...6).contains(sessionsPerWeek) {
			throw refusal("sessionsPerWeek must be a whole number from 3 to 6 when given.")
		}
		return SampleWeekRequest(
			tier: tier, scheduleType: scheduleType, availableDays: availableDays,
			keySessionDay: keySessionDay, sessionsPerWeek: sessionsPerWeek)
	}

	private static func optional<Choice: RawRepresentable & CaseIterable>(
		_ fields: [String: JSONValue], _ key: String, _ choices: Choice.Type
	) throws(ToolInputError) -> Choice? where Choice.RawValue == String {
		guard fields[key] != nil else { return nil }
		return try required(fields, key, choices)
	}

	private static func list<Choice: RawRepresentable & CaseIterable>(
		_ fields: [String: JSONValue], _ key: String, _ choices: Choice.Type
	) throws(ToolInputError) -> [Choice]? where Choice.RawValue == String {
		guard let value = fields[key] else { return nil }
		guard let items = value.arrayValue else {
			throw refusal("\(key) must be a list when given.")
		}
		var chosen: [Choice] = []
		for item in items {
			guard let raw = item.stringValue, let choice = Choice(rawValue: raw) else {
				let names = Choice.allCases.map(\.rawValue).joined(separator: ", ")
				throw refusal("Each of \(key) must be one of \(names).")
			}
			chosen.append(choice)
		}
		return chosen
	}
}
