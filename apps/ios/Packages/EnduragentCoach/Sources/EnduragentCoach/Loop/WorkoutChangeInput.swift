import Foundation

extension PreparationRequest {
	private enum Kind: String {
		case complete, replace, revise, incomplete

		var fields: Set<String> {
			switch self {
			case .complete: ["kind", "changes"]
			case .replace: ["kind", "base", "changes"]
			case .revise: ["kind", "base", "replacements"]
			case .incomplete: ["kind", "reason"]
			}
		}
	}

	init(arguments: JSONValue, today: CivilDate) throws(ToolInputError) {
		let preparation = try StrictObject(
			arguments, at: "arguments", allowing: ["preparation"]
		).required("preparation")
		guard
			let kind = preparation.objectFields["kind"]?.stringValue.flatMap(Kind.init(rawValue:))
		else {
			throw .invalid("preparation.kind must be complete, replace, revise or incomplete.")
		}
		let fields = try StrictObject(preparation, at: "preparation", allowing: kind.fields)
		switch kind {
		case .complete:
			self = .complete(try Self.changes(fields.required("changes"), today: today))
		case .replace:
			self = .replace(
				try Self.base(fields.required("base")),
				try Self.changes(fields.required("changes"), today: today))
		case .revise:
			self = .revise(
				try Self.base(fields.required("base")),
				try Self.replacements(fields.required("replacements"), today: today))
		case .incomplete:
			guard
				try fields.required("reason").stringValue?
					.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
			else {
				throw .invalid("preparation.reason must say why the set is incomplete.")
			}
			self = .incomplete
		}
	}

	private static func changes(_ value: JSONValue, today: CivilDate) throws(ToolInputError)
		-> [ProposedChange]
	{
		var changes: [ProposedChange] = []
		for (index, item) in try nonEmpty(value, at: "preparation.changes").enumerated() {
			changes.append(
				try ProposedChange(item, at: "preparation.changes[\(index)]", today: today))
		}
		return changes
	}

	private static func replacements(_ value: JSONValue, today: CivilDate)
		throws(ToolInputError) -> [ChangeID: ProposedChange]
	{
		var replacements: [ChangeID: ProposedChange] = [:]
		for (index, item) in try nonEmpty(value, at: "preparation.replacements").enumerated() {
			let path = "preparation.replacements[\(index)]"
			let fields = try StrictObject(item, at: path, allowing: ["id", "change"])
			let raw = try fields.required("id").stringValue ?? ""
			guard let ulid = ULID(rawValue: raw) else {
				throw ToolInputError(
					code: "unknown_item",
					details:
						"\(path).id \(raw) is not a pending item id. Item ids come from get_pending_workout_changes and differ from calendar event ids."
				)
			}
			let id = ChangeID(ulid: ulid)
			guard replacements[id] == nil else {
				throw .invalid("Each pending workout may be revised only once.")
			}
			replacements[id] = try ProposedChange(
				try fields.required("change"), at: "\(path).change", today: today)
		}
		return replacements
	}

	private static func base(_ value: JSONValue) throws(ToolInputError) -> ReviewBase {
		let fields = try StrictObject(
			value, at: "preparation.base", allowing: ["setId", "revision"])
		guard let ulid = ULID(rawValue: try fields.required("setId").stringValue ?? "") else {
			throw .invalid(
				"preparation.base.setId must be the setId from get_pending_workout_changes.")
		}
		guard let revision = try fields.required("revision").numberValue.flatMap(wholeInt),
			revision > 0
		else {
			throw .invalid("preparation.base.revision must be a whole number of at least 1.")
		}
		return ReviewBase(
			review: WorkoutReviewID(ulid: ulid), revision: ReviewRevision(rawValue: revision))
	}

	private static func nonEmpty(_ value: JSONValue, at path: String) throws(ToolInputError)
		-> [JSONValue]
	{
		guard let items = value.arrayValue, !items.isEmpty else {
			throw .invalid("\(path) must be a list of at least one change.")
		}
		return items
	}
}

extension ProposedChange {
	private enum Kind: String {
		case addCycling = "add-cycling"
		case addStrength = "add-strength"
		case edit, delete

		var fields: Set<String> {
			switch self {
			case .addCycling: ["kind", "date", "workout", "trainingLoad"]
			case .addStrength:
				[
					"kind", "date", "name", "durationMinutes", "effort", "description",
					"trainingLoad",
				]
			case .edit: ["kind", "eventId", "patch"]
			case .delete: ["kind", "eventId"]
			}
		}
	}

	fileprivate init(_ change: JSONValue, at path: String, today: CivilDate)
		throws(ToolInputError)
	{
		guard let kind = change.objectFields["kind"]?.stringValue.flatMap(Kind.init(rawValue:))
		else {
			throw .invalid("\(path).kind must be add-cycling, add-strength, edit or delete.")
		}
		let fields = try StrictObject(change, at: path, allowing: kind.fields)
		switch kind {
		case .addCycling:
			self = .add(
				try at(path) { () throws(ToolInputError) in
					try CalendarPayload.ride(change, today: today)
				})
		case .addStrength:
			self = .add(
				try at(path) { () throws(ToolInputError) in
					try CalendarPayload.strength(change, today: today)
				})
		case .edit:
			let event = try Self.event(fields)
			let patch = try fields.required("patch")
			self = .edit(
				event,
				try at("\(path).patch") { () throws(ToolInputError) in
					try WorkoutPatch.parse(patch, today: today)
				})
		case .delete:
			self = .delete(try Self.event(fields))
		}
	}

	private static func event(_ fields: StrictObject) throws(ToolInputError) -> EventID {
		guard let id = try fields.required("eventId").numberValue.flatMap(wholeInt) else {
			throw ToolInputError(
				code: "invalid_event_id", details: "\(fields.path).eventId must be an integer.")
		}
		return EventID(rawValue: id)
	}
}

private struct StrictObject {
	let path: String
	let values: [String: JSONValue]

	init(_ value: JSONValue, at path: String, allowing allowed: Set<String>)
		throws(ToolInputError)
	{
		guard case .object(let values) = value else { throw .invalid("\(path) must be an object.") }
		if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
			throw .invalid("\(path) has an unknown field \(unknown).")
		}
		self.path = path
		self.values = values
	}

	func required(_ key: String) throws(ToolInputError) -> JSONValue {
		guard let value = values[key] else { throw .invalid("\(path).\(key) is required.") }
		return value
	}
}

private func at<Parsed>(_ path: String, _ parse: () throws(ToolInputError) -> Parsed)
	throws(ToolInputError) -> Parsed
{
	do {
		return try parse()
	} catch {
		throw ToolInputError(code: error.code, details: "\(path): \(error.details)")
	}
}

extension ToolInputError {
	fileprivate static func invalid(_ details: String) -> ToolInputError {
		ToolInputError(code: "invalid_input", details: details)
	}
}
