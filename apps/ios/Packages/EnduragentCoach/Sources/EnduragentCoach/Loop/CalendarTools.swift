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

	static let getPendingWorkoutChanges = CoachTool.training(
		.preparation(.getPendingWorkoutChanges),
		"Read the workout review that waits for the athlete's approval: its reference (setId and revision), the count of changes already written, and each remaining change with its item id. Item ids differ from calendar event ids. Read this before revising or replacing a pending review.",
		parameters: ToolParameters.none,
		rerunWith: nil
	) { _, reach in
		.result(try await reach.local.desk.pending(chat: reach.local.chat).json)
	}

	static let prepareWorkoutChanges = CoachTool.training(
		.preparation(.prepareWorkoutChanges),
		"Prepare the entire requested set of calendar additions, edits and deletions for one athlete review. Submit once per turn, including single workouts. This does not write to the calendar. Use incomplete with a reason when any requested change cannot be prepared; never submit a partial set. For a pending review, first read get_pending_workout_changes, then use revise with its base reference and the item ids to replace, or replace for an explicitly requested whole-set replacement. Use complete only without a pending review. Cycling additions use structured steps; strength additions need durationMinutes and effort. Edit patches accept date, name, durationSeconds, description, trainingLoad and structure. Today and future dates only; edits and deletions need coach-created workouts, and each workout may appear once. Other workouts on the same dates are kept.",
		parameters: ToolParameters.object(
			properties: [
				"preparation": .object([
					"type": .string("object"),
					"description": .string(
						"kind complete with changes; replace with base and changes; revise with base and replacements [{id, change}]; or incomplete with reason. A change is {kind: add-cycling, date, workout, trainingLoad?}, {kind: add-strength, date, name, durationMinutes, effort, description, trainingLoad?}, {kind: edit, eventId, patch} or {kind: delete, eventId}. base is {setId, revision} from get_pending_workout_changes."
					),
					"properties": .object([
						"kind": .object([
							"type": .string("string"),
							"enum": .array(
								["complete", "replace", "revise", "incomplete"].map(
									JSONValue.string)),
						]),
						"changes": .object([
							"type": .string("array"),
							"items": .object(["type": .string("object")]),
						]),
						"base": ToolParameters.object(
							properties: [
								"setId": ToolParameters.string("The pending review's setId"),
								"revision": ToolParameters.integer(
									"The pending review's revision", minimum: 1),
							],
							required: ["setId", "revision"]),
						"replacements": .object([
							"type": .string("array"),
							"items": ToolParameters.object(
								properties: [
									"id": ToolParameters.string("A pending item id"),
									"change": .object(["type": .string("object")]),
								],
								required: ["id", "change"]),
						]),
						"reason": ToolParameters.string("Why the requested set cannot be prepared"),
					]),
					"required": .array([.string("kind")]),
				])
			],
			required: ["preparation"]
		),
		rerunWith: nil
	) { arguments, reach in
		let local = reach.local
		let request = try PreparationRequest(arguments: arguments, today: local.today)
		let reply = await local.desk.prepare(
			request, for: local.attempt, chat: local.chat, binding: local.scope.stamp.binding,
			reads: reach.calendar)
		return .result(reply.json)
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
