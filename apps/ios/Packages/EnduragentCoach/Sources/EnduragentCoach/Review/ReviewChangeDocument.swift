import Foundation

struct ChangeDocument: Codable {
	let id: String
	let position: Int
	let action: ActionDocument

	init(_ change: ReviewChange) {
		id = change.id.ulid.rawValue
		position = change.position
		action = ActionDocument(change.action)
	}

	func change() throws -> ReviewChange {
		ReviewChange(
			id: ChangeID(ulid: try decodeULID(id)), position: position, action: try action.action())
	}
}

struct FinishedDocument: Codable {
	let change: ChangeDocument
	let result: ResultDocument

	init(_ finished: FinishedChange) {
		change = ChangeDocument(finished.change)
		result = ResultDocument(finished.result)
	}

	func finished() throws -> FinishedChange {
		FinishedChange(change: try change.change(), result: result.result)
	}
}

enum ResultDocument: Codable {
	case saved(receipt: Receipt)
	case seenOnCalendar(event: Int)
	case noLongerOnCalendar

	init(_ result: ChangeResult) {
		self =
			switch result {
			case .saved(let receipt): .saved(receipt: receipt)
			case .seenOnCalendar(let event): .seenOnCalendar(event: event.rawValue)
			case .noLongerOnCalendar: .noLongerOnCalendar
			}
	}

	var result: ChangeResult {
		switch self {
		case .saved(let receipt): .saved(receipt)
		case .seenOnCalendar(let event): .seenOnCalendar(EventID(rawValue: event))
		case .noLongerOnCalendar: .noLongerOnCalendar
		}
	}
}

enum ActionDocument: Codable {
	case add(payload: PayloadDocument, identity: UUID)
	case edit(target: TargetDocument, patch: PatchDocument)
	case delete(target: TargetDocument)

	init(_ action: ChangeAction) {
		self =
			switch action {
			case .add(let add):
				.add(payload: PayloadDocument(add.payload), identity: add.identity.rawValue)
			case .edit(let edit):
				.edit(target: TargetDocument(edit.target), patch: PatchDocument(edit.patch))
			case .delete(let delete): .delete(target: TargetDocument(delete.target))
			}
	}

	func action() throws -> ChangeAction {
		switch self {
		case .add(let payload, let identity):
			.add(
				AddedWorkout(
					payload: try payload.payload(), identity: CalendarWriteID(rawValue: identity)))
		case .edit(let target, let patch):
			.edit(EditedWorkout(target: try target.target(), patch: try patch.patch()))
		case .delete(let target): .delete(DeletedWorkout(target: try target.target()))
		}
	}
}

enum TargetDocument: Codable {
	case reviewed(event: Int, snapshot: SnapshotDocument)
	case upgradedWithoutSnapshot(event: Int, date: String)

	init(_ target: ReviewedTarget) {
		self =
			switch target {
			case .reviewed(let event, let snapshot):
				.reviewed(event: event.rawValue, snapshot: SnapshotDocument(snapshot))
			case .upgradedWithoutSnapshot(let event, let date):
				.upgradedWithoutSnapshot(event: event.rawValue, date: date.rawValue)
			}
	}

	func target() throws -> ReviewedTarget {
		switch self {
		case .reviewed(let event, let snapshot):
			.reviewed(EventID(rawValue: event), try snapshot.snapshot())
		case .upgradedWithoutSnapshot(let event, let date):
			.upgradedWithoutSnapshot(EventID(rawValue: event), try decodeCivilDate(date))
		}
	}
}

struct SnapshotDocument: Codable {
	let date: String
	let name: String?
	let durationSeconds: Int?
	let description: String?
	let load: Int?
	let structure: String?

	init(_ snapshot: WorkoutSnapshot) {
		date = snapshot.date.rawValue
		name = snapshot.name
		durationSeconds = snapshot.durationSeconds
		description = snapshot.description
		load = snapshot.load
		structure = snapshot.structure
	}

	func snapshot() throws -> WorkoutSnapshot {
		WorkoutSnapshot(
			date: try decodeCivilDate(date), name: name, durationSeconds: durationSeconds,
			description: description, load: load, structure: structure)
	}
}

struct PayloadDocument: Codable {
	let date: String
	let type: String
	let name: String
	let description: String
	let movingTime: Int?
	let trainingLoad: Int?
	let authoredSteps: String?

	init(_ payload: CalendarPayload) {
		date = payload.date.rawValue
		type = payload.type.rawValue
		name = payload.name
		description = payload.description
		movingTime = payload.movingTime
		trainingLoad = payload.trainingLoad
		authoredSteps = payload.authoredSteps.map { canonicalJSON($0.json) }
	}

	func payload() throws -> CalendarPayload {
		guard let type = CalendarEventType(rawValue: type) else {
			throw RecordDecodeFailure(reason: "workout type")
		}
		return CalendarPayload(
			date: try decodeCivilDate(date), type: type, name: name, description: description,
			movingTime: movingTime, trainingLoad: trainingLoad,
			authoredSteps: try authoredSteps.map { raw in
				try AuthoredSteps.ride(try JSONValue.parse(raw))
			})
	}
}

struct PatchDocument: Codable {
	let date: String?
	let name: String?
	let durationSeconds: Int?
	let description: String?
	let trainingLoad: Int?
	let workoutDocument: String?
	let authoredSteps: String?

	init(_ patch: WorkoutPatch) {
		date = patch.date?.rawValue
		name = patch.name
		durationSeconds = patch.durationSeconds
		description = patch.description
		trainingLoad = patch.trainingLoad
		workoutDocument = patch.workoutDocument.map(canonicalJSON)
		authoredSteps = patch.authoredSteps.map { canonicalJSON($0.json) }
	}

	func patch() throws -> WorkoutPatch {
		WorkoutPatch(
			date: try date.map(decodeCivilDate), name: name, durationSeconds: durationSeconds,
			description: description, trainingLoad: trainingLoad,
			workoutDocument: try workoutDocument.map { (raw) throws(DecodingError) in
				try JSONValue.parse(raw)
			},
			authoredSteps: try authoredSteps.map { raw in
				try AuthoredSteps.structure(try JSONValue.parse(raw))
			})
	}
}
