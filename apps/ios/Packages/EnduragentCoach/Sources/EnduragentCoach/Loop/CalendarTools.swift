import Foundation

extension CoachTools {
	static let listEvents = CoachTool.training(
		.read(.intervalsListEvents),
		"List the workouts and races (categories WORKOUT, RACE_A, RACE_B and RACE_C) on the intervals.icu calendar for a date range; notes, holidays and other entries are left out. Use this BEFORE deleting so you can show the athlete the list (id, date, name) and ask which one to delete. A row has name when the entry has one, durationSeconds when intervals.icu holds its moving time, and load when intervals.icu holds its training Load; a missing key means unknown, never zero. Races are listed to plan around and are never changeable. Each row carries a coachCreated flag; only coach-created workouts can be deleted with intervals_delete_workout. Pass coachCreatedOnly: true to list only coach-created rows; a coach-created race stays a race and is still never changeable.",
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
		),
		rerunWith: "a smaller date range"
	) { arguments, reach in
		let range = try arguments.readRange(today: reach.local.today)
		var events = try await reach.calendar.listEvents(in: range).filter {
			listedCategories.contains($0.category)
		}
		if arguments.objectFields["coachCreatedOnly"]?.boolValue == true {
			events = events.filter(\.coachCreated)
		}
		return .result(.array(events.map(encodeEvent)))
	}

	static let createWorkout = CoachTool.proposal(
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
	) { (arguments, today) throws(ToolInputError) in
		let parsed = try CyclingTools.parseCreateWorkoutInput(arguments, today: today)
		return (
			.createWorkout(date: parsed.date, workout: parsed.workout),
			parsed.description
		)
	}

	static let createStrengthWorkout = CoachTool.proposal(
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
	) { (arguments, today) throws(ToolInputError) in
		let parsed = try CyclingTools.parseStrengthWorkout(arguments, today: today)
		return (
			.createStrengthWorkout(
				date: parsed.date, name: parsed.name, description: parsed.description),
			parsed.description
		)
	}

	static let deleteWorkout = CoachTool.proposal(
		.intervalsDeleteWorkout,
		"List and confirm first. Delete a today-or-future coach-owned workout by event ID.",
		parameters: ToolParameters.object(
			properties: [
				"eventId": ToolParameters.integer("Event ID from intervals_list_events")
			],
			required: ["eventId"]
		)
	) { (arguments, _) throws(ToolInputError) in
		(.deleteWorkout(eventId: try CyclingTools.parseDeleteWorkout(arguments)), "")
	}

	static let updateWorkout = CoachTool.proposal(
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
	) { (arguments, today) throws(ToolInputError) in
		let update = try CyclingTools.parseUpdateWorkout(arguments, today: today)
		return (.updateWorkout(update), update.description ?? "")
	}

	private static let listedCategories: Set<String> = ["WORKOUT", "RACE_A", "RACE_B", "RACE_C"]

	private static func encodeEvent(_ event: CalendarEvent) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .number(Double(event.id.rawValue)),
			"startDateLocal": .string(event.startDateLocal),
			"category": .string(event.category),
			"tags": .array(event.tags.map { .string($0) }),
			"coachCreated": .bool(event.coachCreated),
		]
		if let name = event.name {
			fields["name"] = .string(name)
		}
		if let movingTime = event.movingTime {
			fields["durationSeconds"] = .number(Double(movingTime))
		}
		if let trainingLoad = event.trainingLoad {
			fields["load"] = .number(Double(trainingLoad))
		}
		if let externalId = event.externalId {
			fields["externalId"] = .string(externalId)
		}
		if let uid = event.uid {
			fields["uid"] = .string(uid)
		}
		return .object(fields)
	}
}

extension CoachTool {
	fileprivate typealias ParseProposal =
		@Sendable (JSONValue, CivilDate) throws(ToolInputError)
		-> (input: GatedToolInput, description: String)

	fileprivate static func proposal(
		_ tool: GatedToolName, _ description: String, parameters: JSONValue,
		parse: @escaping ParseProposal
	) -> CoachTool {
		training(.proposal(tool), description, parameters: parameters, rerunWith: nil) {
			arguments, reach in
			let local = reach.local
			let parsed = try parse(arguments, local.today)
			let proposal = try await local.reviews.propose(
				chatId: local.chat,
				tool: tool,
				input: parsed.input,
				summary: ProposalPolicy.summary(for: parsed.input),
				description: parsed.description,
				scope: local.scope
			)
			return ToolExecution(outcome: .pending(proposal), commit: nil)
		}
	}
}
