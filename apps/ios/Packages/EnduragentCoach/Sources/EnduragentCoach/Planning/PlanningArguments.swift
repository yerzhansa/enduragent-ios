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

	private static let largestSafeInteger = 9_007_199_254_740_991.0

	private static func object(_ arguments: JSONValue) throws(ToolInputError)
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
}
