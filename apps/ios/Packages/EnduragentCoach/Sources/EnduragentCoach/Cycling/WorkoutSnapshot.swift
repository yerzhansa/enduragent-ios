import Foundation

package struct WorkoutSnapshot: Hashable, Sendable {
	package let date: CivilDate
	package let name: String?
	package let durationSeconds: Int?
	package let description: String?
	package let load: Int?
	package let structure: String?

	static func normalizedText(_ text: String) -> String {
		text.replacingOccurrences(of: "\r\n", with: "\n")
	}

	static func normalizedStructure(_ document: JSONValue) -> String? {
		document == .null ? nil : normalizedJSON(document).canonicalDigestInput()
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
