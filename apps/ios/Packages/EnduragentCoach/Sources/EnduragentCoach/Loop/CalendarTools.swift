import Foundation

extension CoachTools {
	static let listEvents = CoachTool.training(
		.intervalsListEvents,
		"List scheduled calendar workouts on intervals.icu for a date range. Use this BEFORE deleting so you can show the athlete the list (id, date, name) and ask which one to delete. Filters to WORKOUT category only. Each row carries a coachCreated flag; only coach-created workouts can be deleted with intervals_delete_workout. Pass coachCreatedOnly: true to return only coach-created events.",
		parameters: ToolParameters.object(
			properties: [
				"oldest": ToolParameters.string("Oldest date (YYYY-MM-DD)"),
				"newest": ToolParameters.string("Newest date (YYYY-MM-DD)"),
				"coachCreatedOnly": .object([
					"type": .string("boolean"),
					"description": .string("Return only events created by this coach"),
				]),
			],
			required: ["oldest"]
		)
	) { arguments, reach in
		let range = try arguments.readRange(today: reach.local.today)
		var events = try await reach.calendar.listEvents(
			oldest: range.oldest, newest: range.newest)
		if arguments.objectFields["coachCreatedOnly"]?.boolValue == true {
			events = events.filter(\.coachCreated)
		}
		return .result(.array(events.map(encodeEvent)))
	}

	static let createWorkout = CoachTool.training(
		.intervalsCreateWorkout,
		"Call this only when the current message explicitly asks for it. Create a structured workout on the intervals.icu calendar. Past dates are refused — workouts can only be created for today or later.",
		parameters: ToolParameters.object(
			properties: [
				"date": ToolParameters.string("Workout date (YYYY-MM-DD)"),
				"workout": .object([
					"type": .string("object"),
					"description": .string("Structured workout with name and steps"),
				]),
			],
			required: ["date", "workout"]
		)
	) { arguments, reach in
		try await propose(.intervalsCreateWorkout, in: reach.local) { today in
			let parsed = try CyclingTools.parseCreateWorkoutInput(arguments, today: today)
			return (
				.createWorkout(date: parsed.date, workout: parsed.workout),
				parsed.draft.description
			)
		}
	}

	static let createStrengthWorkout = CoachTool.training(
		.intervalsCreateStrengthWorkout,
		"Create a strength/gym session on the intervals.icu calendar. Past dates are refused — sessions can only be created for today or later.",
		parameters: ToolParameters.object(
			properties: [
				"date": ToolParameters.string("Session date (YYYY-MM-DD)"),
				"name": ToolParameters.string("Calendar card title"),
				"description": ToolParameters.string("Free-text session content"),
			],
			required: ["date", "name", "description"]
		)
	) { arguments, reach in
		try await propose(.intervalsCreateStrengthWorkout, in: reach.local) { today in
			let parsed = try CyclingTools.parseStrengthWorkout(arguments, today: today)
			return (
				.createStrengthWorkout(
					date: parsed.date, name: parsed.name, description: parsed.description),
				parsed.description
			)
		}
	}

	static let deleteWorkout = CoachTool.training(
		.intervalsDeleteWorkout,
		"List and confirm first. Delete a today-or-future coach-owned workout by event ID.",
		parameters: ToolParameters.object(
			properties: [
				"eventId": ToolParameters.integer("Event ID from intervals_list_events")
			],
			required: ["eventId"]
		)
	) { arguments, reach in
		try await propose(.intervalsDeleteWorkout, in: reach.local) { _ in
			(.deleteWorkout(eventId: try CyclingTools.parseDeleteWorkout(arguments)), "")
		}
	}

	static let updateWorkout = CoachTool.training(
		.intervalsUpdateWorkout,
		"Update a today-or-future coach-owned workout by event ID.",
		parameters: ToolParameters.object(
			properties: [
				"eventId": ToolParameters.integer("Event ID from intervals_list_events"),
				"date": ToolParameters.string("New workout date (YYYY-MM-DD)"),
				"name": ToolParameters.string("New calendar title"),
				"description": ToolParameters.string("New description"),
			],
			required: ["eventId"]
		)
	) { arguments, reach in
		try await propose(.intervalsUpdateWorkout, in: reach.local) { today in
			let update = try CyclingTools.parseUpdateWorkout(arguments, today: today)
			return (.updateWorkout(update), update.description ?? "")
		}
	}

	private static func propose(
		_ tool: GatedToolName, in reach: LocalReach,
		parsed: (CivilDate) throws -> (input: GatedToolInput, description: String)
	) async throws -> ToolExecution {
		do {
			let (input, description) = try parsed(reach.today)
			let proposal = try await reach.reviews.propose(
				chatId: reach.chat,
				tool: tool,
				input: input,
				summary: ProposalPolicy.summary(for: input),
				description: description,
				scope: reach.scope
			)
			return ToolExecution(outcome: .pending(proposal), commit: nil)
		} catch let error as InvalidWorkout {
			return .result(
				.object([
					"error": .string("invalid_workout"),
					"details": .string(error.message),
				]))
		}
	}

	private static func encodeEvent(_ event: CalendarEvent) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .number(Double(event.id.rawValue)),
			"startDateLocal": .string(event.startDateLocal),
			"name": .string(event.name),
			"category": .string(event.category),
			"tags": .array(event.tags.map { .string($0) }),
			"coachCreated": .bool(event.coachCreated),
		]
		if let externalId = event.externalId {
			fields["externalId"] = .string(externalId)
		}
		if let uid = event.uid {
			fields["uid"] = .string(uid)
		}
		return .object(fields)
	}
}
