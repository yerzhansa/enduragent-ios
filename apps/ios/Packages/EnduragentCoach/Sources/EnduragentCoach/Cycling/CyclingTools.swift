import Foundation

package enum CyclingTools {
	package static func parseCreateWorkoutInput(
		_ arguments: JSONValue,
		today: CivilDate
	) throws(ToolInputError)
		-> (date: CivilDate, workout: IntervalsWorkoutInput, description: String)
	{
		let fields = arguments.objectFields
		guard let dateRaw = fields["date"]?.stringValue else {
			throw ToolInputError(
				code: "invalid_date",
				details: "date is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		guard let date = CivilDate(rawValue: dateRaw) else {
			throw ToolInputError(
				code: "invalid_date",
				details: "\(dateRaw) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		try IntervalsPolicy.rejectPastCreationDate(date, today: today)
		let workout: IntervalsWorkoutInput
		let serialized: SerializedWorkout
		do throws(InvalidWorkout) {
			guard let workoutJSON = fields["workout"] else {
				throw InvalidWorkout(message: "workout: Required")
			}
			workout = try IntervalsSerializer.parseWorkout(workoutJSON)
			serialized = try IntervalsSerializer.serialize(workout)
		} catch {
			throw ToolInputError(code: "invalid_workout", details: error.message)
		}
		return (date, workout, serialized.description)
	}

	package static func parseStrengthWorkout(
		_ arguments: JSONValue,
		today: CivilDate
	) throws(ToolInputError)
		-> (date: CivilDate, name: String, description: String)
	{
		let fields = arguments.objectFields
		guard let dateRaw = fields["date"]?.stringValue, let date = CivilDate(rawValue: dateRaw)
		else {
			let raw = fields["date"]?.stringValue ?? ""
			throw ToolInputError(
				code: "invalid_date",
				details: raw.isEmpty
					? "date is not a real calendar date. Use YYYY-MM-DD."
					: "\(raw) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		try IntervalsPolicy.rejectPastCreationDate(date, today: today)
		guard let name = fields["name"]?.stringValue, (1...120).contains(name.count) else {
			throw ToolInputError(
				code: "invalid_input", details: "name must be 1 to 120 characters.")
		}
		guard let description = fields["description"]?.stringValue,
			(1...4000).contains(description.count)
		else {
			throw ToolInputError(
				code: "invalid_input", details: "description must be 1 to 4000 characters.")
		}
		return (date, name, description)
	}

	package static func parseDeleteWorkout(_ arguments: JSONValue) throws(ToolInputError)
		-> EventID
	{
		guard let eventId = arguments.objectFields["eventId"]?.intValue() else {
			throw ToolInputError(code: "invalid_event_id", details: "eventId must be an integer.")
		}
		return EventID(rawValue: eventId)
	}

	package static func parseUpdateWorkout(_ arguments: JSONValue, today: CivilDate)
		throws(ToolInputError) -> UpdateWorkoutInput
	{
		let fields = arguments.objectFields
		guard let eventId = fields["eventId"]?.intValue() else {
			throw ToolInputError(code: "invalid_event_id", details: "eventId must be an integer.")
		}
		let changes = fields["changes"]?.objectFields ?? fields
		let date: CivilDate?
		if let dateRaw = changes["date"]?.stringValue {
			guard let parsed = CivilDate(rawValue: dateRaw) else {
				throw ToolInputError(
					code: "invalid_date",
					details: "\(dateRaw) is not a real calendar date. Use YYYY-MM-DD."
				)
			}
			if Eligibility.refusal(ofAddOn: parsed, today: today) != nil {
				throw ToolInputError(
					code: "past_date_refused",
					details:
						"Cannot move a workout to \(parsed.rawValue) — it's before today (\(today.rawValue)). Use today's date or later."
				)
			}
			date = parsed
		} else {
			date = nil
		}
		let name = changes["name"]?.stringValue
		let description = changes["description"]?.stringValue
		if date == nil && name == nil && description == nil {
			throw ToolInputError(
				code: "invalid_changes", details: "At least one workout field must change.")
		}
		return UpdateWorkoutInput(
			eventId: EventID(rawValue: eventId),
			date: date,
			name: name,
			description: description
		)
	}
}

extension JSONValue {
	package var objectFields: [String: JSONValue] {
		if case .object(let fields) = self { return fields }
		return [:]
	}

	package var arrayValue: [JSONValue]? {
		if case .array(let items) = self { return items }
		return nil
	}

	package var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	package var numberValue: Double? {
		if case .number(let value) = self { return value }
		return nil
	}

	package var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	package func intValue() -> Int? {
		switch self {
		case .number(let value):
			return wholeInt(value)
		case .string(let value):
			return Int(value)
		default:
			return nil
		}
	}
}
