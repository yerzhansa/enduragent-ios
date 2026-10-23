import Foundation

package struct WorkoutSnapshot: Equatable, Sendable {
	package let date: CivilDate
	package let name: String?
	package let durationSeconds: Int?
	package let description: String?
	package let load: Int?
	package let structure: String?

	static func normalizedText(_ text: String) -> String {
		text.replacingOccurrences(of: "\r\n", with: "\n")
	}

	var hasParsedSteps: Bool { structure != nil }

	package static func == (left: WorkoutSnapshot, right: WorkoutSnapshot) -> Bool {
		left.date == right.date && left.name == right.name
			&& left.durationSeconds == right.durationSeconds
			&& left.description == right.description && left.load == right.load
			&& sameStructure(left.structure, right.structure)
	}

	static func sameStructure(_ left: String?, _ right: String?) -> Bool {
		left == right || left.map(comparableStructure) == right.map(comparableStructure)
	}

	private static func comparableStructure(_ text: String) -> String {
		do {
			return try JSONValue.parsePrinted(text).canonicalDigestInput()
		} catch is DecodingError {
			return text
		}
	}

	static func normalizedStructure(_ document: JSONValue) -> String? {
		guard let steps = document.objectFields["steps"], steps.arrayValue?.isEmpty == false
		else { return nil }
		return JSONValue.object(["steps": normalizedJSON(steps)]).canonicalDigestInput()
	}

	private static func normalizedJSON(_ value: JSONValue) -> JSONValue {
		switch value {
		case .string(let text): .string(normalizedText(text))
		case .array(let items): .array(items.map(normalizedJSON))
		case .object(let fields): .object(fields.mapValues(normalizedJSON))
		case .null, .bool, .number: value
		}
	}
}

extension CalendarEvent {
	package var snapshot: WorkoutSnapshot {
		get throws(IntervalsError) {
			guard let date = CivilDate(rawValue: String(startDateLocal.prefix(10))) else {
				throw IntervalsError(
					code: "invalid_json", details: "calendar event has an invalid date")
			}
			return WorkoutSnapshot(
				date: date,
				name: name,
				durationSeconds: movingTime,
				description: description.map(WorkoutSnapshot.normalizedText),
				load: trainingLoad,
				structure: workoutDocument.flatMap(WorkoutSnapshot.normalizedStructure)
			)
		}
	}
}
