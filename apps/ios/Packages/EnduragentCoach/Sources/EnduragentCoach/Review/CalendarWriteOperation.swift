import Foundation

struct CalendarWriteOperation: Sendable {
	let input: GatedToolInput
	let draft: ChatCalendarCreate?
	let target: CalendarWriteTarget

	static func prepare(_ live: LiveProposal, client: any IntervalsClient, today: CivilDate)
		async throws -> Self
	{
		let input = live.body.toolInput
		switch input {
		case .createWorkout, .createStrengthWorkout:
			let draft = try creation(live)
			try IntervalsPolicy.rejectPastCreationDate(draft.date, today: today)
			return Self(input: input, draft: draft, target: .create(date: draft.date.rawValue))
		case .updateWorkout(let update):
			let event = try await client.fetchEvent(id: update.eventId)
			try IntervalsPolicy.refuseMutableEvent(
				event, today: today, eventId: update.eventId, action: "update",
				nextDate: update.date)
			return Self(
				input: input, draft: nil,
				target: .update(
					eventID: update.eventId.rawValue, date: String(event.startDateLocal.prefix(10)))
			)
		case .deleteWorkout(let id):
			let event = try await client.fetchEvent(id: id)
			try IntervalsPolicy.refuseMutableEvent(
				event, today: today, eventId: id, action: "delete", nextDate: nil)
			return Self(
				input: input, draft: nil,
				target: .delete(eventID: id.rawValue, date: String(event.startDateLocal.prefix(10)))
			)
		case .planSave:
			throw IntervalsError(
				code: "not_implemented", details: "Saving a plan is not available yet.")
		}
	}

	private static func creation(_ live: LiveProposal) throws -> ChatCalendarCreate {
		switch live.body.toolInput {
		case .createWorkout(let date, let workout):
			let serialized = try IntervalsSerializer.serialize(workout)
			return ChatCalendarCreate(
				writeID: live.body.writeID, date: date, name: workout.name,
				description: serialized.description, type: .ride,
				externalId: IntervalsSerializer.chatExternalId(date: date, name: workout.name),
				tags: [IntervalsPolicy.coachTag])
		case .createStrengthWorkout(let date, let name, let description):
			return ChatCalendarCreate(
				writeID: live.body.writeID, date: date, name: name, description: description,
				type: .weightTraining,
				externalId: IntervalsSerializer.chatExternalId(
					date: date, name: "strength \(name)"),
				tags: [IntervalsPolicy.coachTag])
		case .updateWorkout, .deleteWorkout, .planSave:
			throw IntervalsError(code: "invalid_operation", details: "Not a calendar creation")
		}
	}

	func dispatch(on client: any IntervalsClient) async throws -> Int {
		try Task.checkCancellation()
		if let draft { return try await client.createChatEvent(draft).id.rawValue }
		switch input {
		case .deleteWorkout(let id):
			try await client.deleteEvent(id: id)
			return id.rawValue
		case .updateWorkout(let update):
			return try await client.updateEvent(
				id: update.eventId, name: update.name, description: update.description,
				date: update.date
			).id.rawValue
		case .createWorkout, .createStrengthWorkout, .planSave:
			throw IntervalsError(
				code: "invalid_operation", details: "Calendar write has no approved payload")
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
			let draft = try creation(live)
			let events = try await client.listEvents(oldest: draft.date, newest: draft.date)
			let matches = events.filter {
				if let writeID = intent.body.writeID {
					return $0.uid == writeID.uid || $0.externalId == writeID.externalID
				}
				return $0.externalId == draft.externalId.rawValue
			}
			guard !matches.isEmpty else { return .unknown(.absent) }
			guard matches.count == 1, let event = matches.first, draft.matches(event)
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

extension ChatCalendarCreate {
	package func matches(_ event: CalendarEvent) -> Bool {
		event.name == name && event.description == description && event.type == type.rawValue
			&& event.category == "WORKOUT" && event.startDateLocal == "\(date.rawValue)T00:00:00"
	}
}
