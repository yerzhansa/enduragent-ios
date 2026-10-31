import Foundation

package struct CalendarPayload: Sendable, Equatable {
	package let date: CivilDate
	package let type: CalendarEventType
	package let name: String
	package let description: String
	package let movingTime: Int?
	package let trainingLoad: Int?
	package let authoredSteps: AuthoredSteps?

	private static let nameLimit = 120
	private static let descriptionLimit = 4000
	private static let largestSafeSeconds = 9_007_199_254_740_991.0

	package static func ride(_ change: JSONValue, today: CivilDate) throws(ToolInputError)
		-> CalendarPayload
	{
		let fields = change.objectFields
		let date = try creationDate(fields["date"], today: today)
		let authored: AuthoredSteps
		let serialized: SerializedWorkout
		do throws(InvalidWorkout) {
			guard let workoutJSON = fields["workout"] else {
				throw InvalidWorkout(message: "workout: Required")
			}
			authored = try AuthoredSteps.ride(workoutJSON)
			serialized = try IntervalsSerializer.serialize(authored.workout)
		} catch {
			throw ToolInputError(code: "invalid_workout", details: error.message)
		}
		guard let movingTime = positiveSafeSeconds(Double(serialized.movingTime)) else {
			throw ToolInputError(
				code: "invalid_workout",
				details: "Workout duration must be a finite number of seconds greater than zero.")
		}
		return CalendarPayload(
			date: date,
			type: .ride,
			name: authored.workout.name,
			description: serialized.description,
			movingTime: movingTime,
			trainingLoad: try trainingLoad(fields["trainingLoad"]),
			authoredSteps: authored
		)
	}

	package static func strength(_ change: JSONValue, today: CivilDate) throws(ToolInputError)
		-> CalendarPayload
	{
		let fields = change.objectFields
		let date = try creationDate(fields["date"], today: today)
		guard
			let name = fields["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
			(1...nameLimit).contains(name.count)
		else {
			throw ToolInputError(
				code: "invalid_input",
				details: "name must be 1 to \(nameLimit) characters after trimming.")
		}
		let movingTime = try strengthSeconds(fields["durationMinutes"])
		guard
			let effort = fields["effort"]?.stringValue?.trimmingCharacters(
				in: .whitespacesAndNewlines),
			!effort.isEmpty
		else {
			throw ToolInputError(
				code: "invalid_input",
				details: "effort must be at least 1 character after trimming.")
		}
		guard let description = fields["description"]?.stringValue,
			(1...descriptionLimit).contains(description.count)
		else {
			throw ToolInputError(
				code: "invalid_input",
				details: "description must be 1 to \(descriptionLimit) characters.")
		}
		return CalendarPayload(
			date: date,
			type: .weightTraining,
			name: name,
			description: "\(effort)\n\n\(description)",
			movingTime: movingTime,
			trainingLoad: try trainingLoad(fields["trainingLoad"]),
			authoredSteps: nil
		)
	}

	package func requestBody(_ identity: CalendarWriteID) -> JSONValue {
		var fields: [String: JSONValue] = [
			"start_date_local": .string("\(date.rawValue)T00:00:00"),
			"category": .string("WORKOUT"),
			"type": .string(type.rawValue),
			"name": .string(name),
			"description": .string(description),
			"external_id": .string(identity.externalID),
			"uid": .string(identity.uid),
			"tags": .array([.string(IntervalsPolicy.coachTag)]),
		]
		if let movingTime {
			fields["moving_time"] = .number(Double(movingTime))
		}
		if let trainingLoad {
			fields["icu_training_load"] = .number(Double(trainingLoad))
		}
		return .object(fields)
	}

	private static func creationDate(_ value: JSONValue?, today: CivilDate)
		throws(ToolInputError) -> CivilDate
	{
		guard let raw = value?.stringValue, let date = CivilDate(rawValue: raw) else {
			throw ToolInputError(
				code: "invalid_date", details: "date is not a real calendar date. Use YYYY-MM-DD.")
		}
		try IntervalsPolicy.rejectPastCreationDate(date, today: today)
		return date
	}

	private static func strengthSeconds(_ value: JSONValue?) throws(ToolInputError) -> Int {
		guard let minutes = value?.numberValue,
			let seconds = positiveSafeSeconds((minutes * 60).rounded(.toNearestOrAwayFromZero))
		else {
			throw ToolInputError(
				code: "invalid_input",
				details: "Strength duration must be a finite number of seconds greater than zero.")
		}
		return seconds
	}

	static func positiveSafeSeconds(_ seconds: Double) -> Int? {
		guard seconds > 0, seconds <= largestSafeSeconds else { return nil }
		return Int(exactly: seconds)
	}

	static func trainingLoad(_ value: JSONValue?) throws(ToolInputError) -> Int? {
		guard let value else { return nil }
		guard let load = value.numberValue, load >= 0,
			let whole = Int(exactly: load.rounded(.toNearestOrAwayFromZero))
		else {
			throw ToolInputError(
				code: "invalid_input", details: "trainingLoad must be a number of at least 0.")
		}
		return whole
	}
}
