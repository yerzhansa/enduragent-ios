import Foundation

public enum CyclingTools {
	public static func parseCreateWorkout(_ arguments: JSONValue, today: CivilDate) throws
		-> ChatCalendarCreate
	{
		let parsed = try parseCreateWorkoutInput(arguments, today: today)
		return parsed.draft
	}

	package static func parseCreateWorkoutInput(
		_ arguments: JSONValue,
		today: CivilDate
	) throws -> (date: CivilDate, workout: IntervalsWorkoutInput, draft: ChatCalendarCreate) {
		let fields = arguments.objectFields
		guard let dateRaw = fields["date"]?.stringValue else {
			throw IntervalsError(
				code: "invalid_date",
				details: "date is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		guard let date = CivilDate(rawValue: dateRaw) else {
			throw IntervalsError(
				code: "invalid_date",
				details: "\(dateRaw) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		try IntervalsPolicy.rejectPastCreationDate(date, today: today)
		guard let workoutJSON = fields["workout"] else {
			throw InvalidWorkout(message: "workout: Required")
		}
		let workout = try IntervalsSerializer.parseWorkout(workoutJSON)
		let serialized = try IntervalsSerializer.serialize(workout)
		let draft = ChatCalendarCreate(
			date: date,
			name: workout.name,
			description: serialized.description,
			type: .ride,
			externalId: IntervalsSerializer.chatExternalId(date: date, name: workout.name),
			tags: [IntervalsPolicy.coachTag]
		)
		return (date, workout, draft)
	}

	package static func parseStrengthWorkout(
		_ arguments: JSONValue,
		today: CivilDate
	) throws -> (date: CivilDate, name: String, description: String, draft: ChatCalendarCreate) {
		let fields = arguments.objectFields
		guard let dateRaw = fields["date"]?.stringValue, let date = CivilDate(rawValue: dateRaw)
		else {
			let raw = fields["date"]?.stringValue ?? ""
			throw IntervalsError(
				code: "invalid_date",
				details: raw.isEmpty
					? "date is not a real calendar date. Use YYYY-MM-DD."
					: "\(raw) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		try IntervalsPolicy.rejectPastCreationDate(date, today: today)
		guard let name = fields["name"]?.stringValue, (1...120).contains(name.count) else {
			throw IntervalsError(
				code: "invalid_input", details: "name must be 1 to 120 characters.")
		}
		guard let description = fields["description"]?.stringValue,
			(1...4000).contains(description.count)
		else {
			throw IntervalsError(
				code: "invalid_input", details: "description must be 1 to 4000 characters.")
		}
		let draft = ChatCalendarCreate(
			date: date,
			name: name,
			description: description,
			type: .weightTraining,
			externalId: IntervalsSerializer.chatExternalId(date: date, name: "strength \(name)"),
			tags: [IntervalsPolicy.coachTag]
		)
		return (date, name, description, draft)
	}

	package static func parseDeleteWorkout(_ arguments: JSONValue) throws -> EventID {
		guard let eventId = arguments.objectFields["eventId"]?.intValue() else {
			throw IntervalsError(code: "invalid_event_id", details: "eventId must be an integer.")
		}
		return EventID(rawValue: eventId)
	}

	package static func parseUpdateWorkout(_ arguments: JSONValue, today: CivilDate) throws
		-> UpdateWorkoutInput
	{
		let fields = arguments.objectFields
		guard let eventId = fields["eventId"]?.intValue() else {
			throw IntervalsError(code: "invalid_event_id", details: "eventId must be an integer.")
		}
		let changes = fields["changes"]?.objectFields ?? fields
		let date: CivilDate?
		if let dateRaw = changes["date"]?.stringValue {
			guard let parsed = CivilDate(rawValue: dateRaw) else {
				throw IntervalsError(
					code: "invalid_date",
					details: "\(dateRaw) is not a real calendar date. Use YYYY-MM-DD."
				)
			}
			if parsed < today {
				throw IntervalsError(
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
			throw IntervalsError(
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
		case .number(let value) where value.rounded(.towardZero) == value:
			return Int(value)
		case .string(let value):
			return Int(value)
		default:
			return nil
		}
	}
}
