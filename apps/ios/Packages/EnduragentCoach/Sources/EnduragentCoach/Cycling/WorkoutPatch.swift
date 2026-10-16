import Foundation

package struct WorkoutPatch: Sendable, Equatable {
	package let date: CivilDate?
	package let name: String?
	package let durationSeconds: Int?
	package let description: String?
	package let trainingLoad: Int?
	package let workoutDocument: JSONValue?

	private static let fieldNames: Set<String> = [
		"date", "name", "durationSeconds", "description", "trainingLoad", "structure",
	]
	private static let nameLimit = 120
	private static let descriptionLimit = 4000

	package static func parse(_ patch: JSONValue, today: CivilDate) throws(ToolInputError)
		-> WorkoutPatch
	{
		guard case .object(let fields) = patch else {
			throw ToolInputError(code: "invalid_input", details: "patch must be an object.")
		}
		if let unknown = fields.keys.sorted().first(where: { !fieldNames.contains($0) }) {
			throw ToolInputError(
				code: "invalid_input", details: "patch has an unknown field \(unknown).")
		}
		guard !fields.isEmpty else {
			throw ToolInputError(
				code: "invalid_input", details: "At least one workout field must change.")
		}
		var durationSeconds = try fields["durationSeconds"].map(parsedDuration)
		var description = try fields["description"].map(parsedDescription)
		var workoutDocument: JSONValue?
		if let structure = fields["structure"] {
			guard case .object = structure else {
				throw ToolInputError(code: "invalid_input", details: "structure must be an object.")
			}
			if isAuthored(structure) {
				let serialized = try authoredSteps(structure)
				durationSeconds = serialized.movingTime
				description = serialized.description
			} else {
				workoutDocument = structure
			}
		}
		return WorkoutPatch(
			date: try fields["date"].map { (value) throws(ToolInputError) in
				try destination(value, today: today)
			},
			name: try fields["name"].map(parsedName),
			durationSeconds: durationSeconds,
			description: description,
			trainingLoad: try CalendarPayload.trainingLoad(fields["trainingLoad"]),
			workoutDocument: workoutDocument
		)
	}

	package func applied(to current: WorkoutSnapshot) -> WorkoutSnapshot {
		let nextDescription = description.map(WorkoutSnapshot.normalizedText) ?? current.description
		let nextStructure: String? =
			if let workoutDocument {
				WorkoutSnapshot.normalizedStructure(workoutDocument)
			} else if WorkoutSnapshot.sameDescription(nextDescription, current.description) {
				current.structure
			} else {
				nil
			}
		return WorkoutSnapshot(
			date: date ?? current.date,
			name: name ?? current.name,
			durationSeconds: durationSeconds ?? current.durationSeconds,
			description: nextDescription,
			load: trainingLoad ?? current.load,
			structure: nextStructure
		)
	}

	package var requestBody: JSONValue {
		var fields: [String: JSONValue] = [:]
		if let date {
			fields["start_date_local"] = .string("\(date.rawValue)T00:00:00")
		}
		if let name {
			fields["name"] = .string(name)
		}
		if let durationSeconds {
			fields["moving_time"] = .number(Double(durationSeconds))
		}
		if let description {
			fields["description"] = .string(description)
		}
		if let trainingLoad {
			fields["icu_training_load"] = .number(Double(trainingLoad))
		}
		if let workoutDocument {
			fields["workout_doc"] = workoutDocument
		}
		return .object(fields)
	}

	private static func authoredSteps(_ structure: JSONValue) throws(ToolInputError)
		-> SerializedWorkout
	{
		let serialized: SerializedWorkout
		do throws(InvalidWorkout) {
			serialized = try IntervalsSerializer.serialize(
				try IntervalsSerializer.parseStructuredSteps(structure))
		} catch {
			throw ToolInputError(code: "invalid_workout", details: error.message)
		}
		guard let movingTime = CalendarPayload.positiveSafeSeconds(Double(serialized.movingTime))
		else {
			throw ToolInputError(
				code: "invalid_workout",
				details: "Workout duration must be a finite number of seconds greater than zero.")
		}
		return SerializedWorkout(description: serialized.description, movingTime: movingTime)
	}

	private static func destination(_ value: JSONValue, today: CivilDate) throws(ToolInputError)
		-> CivilDate
	{
		guard let raw = value.stringValue, let date = CivilDate(rawValue: raw) else {
			throw ToolInputError(
				code: "invalid_date", details: "date is not a real calendar date. Use YYYY-MM-DD.")
		}
		if date < today {
			throw ToolInputError(
				code: "past_workout_destination",
				details:
					"Cannot move workout to \(date.rawValue) — it's before today (\(today.rawValue))."
			)
		}
		return date
	}

	private static func parsedName(_ value: JSONValue) throws(ToolInputError) -> String {
		guard let name = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
			(1...nameLimit).contains(name.count)
		else {
			throw ToolInputError(
				code: "invalid_input",
				details: "name must be 1 to \(nameLimit) characters after trimming.")
		}
		return name
	}

	private static func parsedDuration(_ value: JSONValue) throws(ToolInputError) -> Int {
		guard let seconds = value.numberValue,
			let whole = CalendarPayload.positiveSafeSeconds(seconds)
		else {
			throw ToolInputError(
				code: "invalid_input",
				details: "durationSeconds must be a whole number of seconds greater than zero.")
		}
		return whole
	}

	private static func parsedDescription(_ value: JSONValue) throws(ToolInputError) -> String {
		guard let description = value.stringValue, description.count <= descriptionLimit else {
			throw ToolInputError(
				code: "invalid_input",
				details: "description must be at most \(descriptionLimit) characters.")
		}
		return description
	}

	private static func isAuthored(_ structure: JSONValue) -> Bool {
		structure.objectFields["steps"]?.arrayValue?.contains(where: isAuthoredStep) ?? false
	}

	private static func isAuthoredStep(_ step: JSONValue) -> Bool {
		guard case .object(let fields) = step else { return false }
		let markers = ["type", "repeat", "interval", "recovery"]
		if markers.contains(where: { fields[$0] != nil }) { return true }
		if case .object(let duration) = fields["duration"],
			duration["value"] != nil || duration["unit"] != nil
		{
			return true
		}
		if case .object(let power) = fields["power"], power["kind"] != nil { return true }
		return false
	}
}
