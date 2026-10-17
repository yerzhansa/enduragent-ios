import Foundation

struct CalendarWriteOperation: Sendable {
	let write: CalendarWrite
	let target: CalendarWriteTarget

	static func prepare(_ live: LiveProposal, client: any IntervalsClient, today: CivilDate)
		async throws -> Self
	{
		switch live.body.toolInput {
		case .createWorkout, .createStrengthWorkout:
			let payload = try creation(live.body.toolInput)
			try IntervalsPolicy.rejectPastCreationDate(payload.date, today: today)
			guard let identity = live.body.writeID else {
				throw IntervalsError(
					code: "missing_write_identity",
					details: "Calendar approval needs a durable identity")
			}
			return Self(
				write: .create(payload, identity: identity),
				target: .create(date: payload.date.rawValue))
		case .updateWorkout(let update):
			let event = try await client.fetchEvent(id: update.eventId)
			try IntervalsPolicy.refuseMutableEvent(
				event, today: today, eventId: update.eventId, action: "update",
				nextDate: update.date)
			return Self(
				write: .update(
					update.eventId,
					WorkoutPatch(
						date: update.date, name: update.name, durationSeconds: nil,
						description: update.description, trainingLoad: nil, workoutDocument: nil,
						authoredSteps: nil)),
				target: .update(
					eventID: update.eventId.rawValue, date: String(event.startDateLocal.prefix(10)))
			)
		case .deleteWorkout(let id):
			let event = try await client.fetchEvent(id: id)
			try IntervalsPolicy.refuseMutableEvent(
				event, today: today, eventId: id, action: "delete", nextDate: nil)
			return Self(
				write: .delete(id),
				target: .delete(eventID: id.rawValue, date: String(event.startDateLocal.prefix(10)))
			)
		case .planSave:
			throw IntervalsError(
				code: "not_implemented", details: "Saving a plan is not available yet.")
		}
	}

	static func creation(_ input: GatedToolInput) throws -> CalendarPayload {
		switch input {
		case .createWorkout(let date, let workout):
			return CalendarPayload(
				date: date, type: .ride, name: workout.name,
				description: try IntervalsSerializer.serialize(workout).description,
				movingTime: nil, trainingLoad: nil, authoredSteps: nil)
		case .createStrengthWorkout(let date, let name, let description):
			return CalendarPayload(
				date: date, type: .weightTraining, name: name, description: description,
				movingTime: nil, trainingLoad: nil, authoredSteps: nil)
		case .updateWorkout, .deleteWorkout, .planSave:
			throw IntervalsError(code: "invalid_operation", details: "Not a calendar creation")
		}
	}

	private static func legacyExternalID(_ input: GatedToolInput) -> String? {
		switch input {
		case .createWorkout(let date, let workout):
			IntervalsSerializer.chatExternalId(date: date, name: workout.name).rawValue
		case .createStrengthWorkout(let date, let name, _):
			IntervalsSerializer.chatExternalId(date: date, name: "strength \(name)").rawValue
		case .updateWorkout, .deleteWorkout, .planSave:
			nil
		}
	}

	func dispatch(on client: any IntervalsClient) async throws -> Int {
		try Task.checkCancellation()
		let event: CalendarEvent?
		switch await client.write(write) {
		case .saved(let saved):
			event = saved
		case .httpStatus(let status):
			throw IntervalsError(code: "http", details: "status \(status)", status: status)
		case .lost(let loss):
			throw IntervalsError(code: "network", details: "The calendar save was lost (\(loss)).")
		}
		switch write {
		case .create(let payload, let identity):
			guard let event, event.uid == identity.uid, payload.matches(event) else {
				throw IntervalsError(
					code: "invalid_json", details: "Created event does not match the approval")
			}
			return event.id.rawValue
		case .update(let id, let patch):
			guard let event, event.id == id, patch.name.map({ $0 == event.name }) ?? true,
				patch.description.map({ $0 == event.description }) ?? true,
				patch.date.map({ "\($0.rawValue)T00:00:00" == event.startDateLocal }) ?? true
			else {
				throw IntervalsError(
					code: "invalid_json", details: "Updated event does not match the approval")
			}
			return event.id.rawValue
		case .delete(let id):
			return id.rawValue
		}
	}

	static func observe(_ intent: CalendarWriteIntent, on client: any IntervalsClient) async throws
		-> CalendarWriteEvidence
	{
		guard let live = intent.proposal else {
			throw IntervalsError(
				code: "missing_payload", details: "Approved content is on another device")
		}
		switch live.body.toolInput {
		case .createWorkout, .createStrengthWorkout:
			let payload = try creation(live.body.toolInput)
			let legacy = legacyExternalID(live.body.toolInput)
			let events = try await client.listEvents(in: .day(payload.date))
			let matches = events.filter {
				if let writeID = intent.body.writeID {
					return $0.uid == writeID.uid || $0.externalId == writeID.externalID
				}
				return $0.externalId == legacy
			}
			guard !matches.isEmpty else { return .unknown(.absent) }
			guard matches.count == 1, let event = matches.first, payload.matches(event)
			else { return .unknown(.found) }
			return .applied(eventID: event.id.rawValue)
		case .updateWorkout(let update):
			guard let event = try await existing(update.eventId, on: client) else {
				return .unknown(.absent)
			}
			guard event.coachCreated, event.category == "WORKOUT",
				update.name.map({ $0 == event.name }) ?? true,
				update.description.map({ $0 == event.description }) ?? true,
				update.date.map({ "\($0.rawValue)T00:00:00" == event.startDateLocal }) ?? true
			else { return .unknown(.found) }
			return .applied(eventID: event.id.rawValue)
		case .deleteWorkout(let id):
			return try await existing(id, on: client) == nil
				? .applied(eventID: id.rawValue) : .unknown(.found)
		case .planSave:
			throw IntervalsError(code: "invalid_operation", details: "Not a calendar write")
		}
	}

	private static func existing(_ id: EventID, on client: any IntervalsClient) async throws
		-> CalendarEvent?
	{
		do { return try await client.fetchEvent(id: id) } catch let error as IntervalsError
			where error.status == 404
		{ return nil }
	}
}

extension CalendarPayload {
	fileprivate func matches(_ event: CalendarEvent) -> Bool {
		event.name == name && event.description == description && event.type == type.rawValue
			&& event.category == "WORKOUT" && event.startDateLocal == "\(date.rawValue)T00:00:00"
	}
}
