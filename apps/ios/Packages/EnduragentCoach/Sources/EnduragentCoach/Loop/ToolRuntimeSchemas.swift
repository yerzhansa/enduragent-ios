import Foundation

extension ToolRuntime {
	package func toolsForTurn(chatId: ChatID, memory: MemoryView) -> [ToolSchema] {
		_ = chatId
		var schemas = [
			ToolSchema(
				name: .calculateZones,
				description: "Calculate power-zone watt ranges from FTP watts (7-zone numbering)",
				parameters: objectSchema(
					properties: [
						"ftpWatts": integerProperty("FTP in watts", minimum: 50, maximum: 600)
					],
					required: ["ftpWatts"]
				)
			),
			ToolSchema(
				name: .intervalsFetchAthlete,
				description:
					"Fetch athlete profile from intervals.icu (FTP, weight, max HR, sport settings, zones)",
				parameters: objectSchema(properties: [:], required: [])
			),
			ToolSchema(
				name: .intervalsFetchWellness,
				description:
					"Fetch wellness data from intervals.icu (fitness, fatigue, weight, HRV, resting HR, sleep). Form = fitness - fatigue.",
				parameters: objectSchema(
					properties: [
						"oldest": stringProperty("Start date (YYYY-MM-DD)"),
						"newest": stringProperty("End date (YYYY-MM-DD)"),
					],
					required: ["oldest"]
				)
			),
			ToolSchema(
				name: .intervalsFetchActivity,
				description:
					"Fetch one recorded activity by legacy or canonical ID. Store-backed results return a bounded source-neutral summary plus laps; other readers may include additional source fields. Use only fields actually returned. Use this for Tier B+ workout reviews; for summary-only Tier A, use `intervals_fetch_activities`.",
				parameters: objectSchema(
					properties: [
						"activityId": stringProperty(Self.activityIDDescription)
					],
					required: ["activityId"]
				)
			),
			ToolSchema(
				name: .intervalsFetchStreams,
				description:
					"Fetch time-series channels for an activity by legacy or canonical ID. Store-backed reads accept up to 16 unique public channels; platform-backed reads also accept provider-specific channels such as smooth_grade. Returns only per-channel min/max/mean over the full series plus the sample count; no per-second data; do not use it for pacing, duration-based best efforts, quartile trends, decoupling, HR recovery, fade patterns, or indoor/outdoor comparisons. Use only minimum, maximum, and mean as descriptive recorded observations. They alone cannot establish session quality, recovery, or readiness, or justify changing the next session. Expensive to fetch (~10,800 samples per type for a 3-hour ride): call it only for Tier C deep reviews the athlete explicitly requests. For Tier A/B use `intervals_fetch_activities` and `intervals_fetch_activity`. Default types: watts, heartrate, cadence, time, altitude.",
				parameters: objectSchema(
					properties: [
						"activityId": stringProperty(Self.activityIDDescription),
						"types": .object([
							"type": .string("array"),
							"items": .object(["type": .string("string")]),
							"description": .string(
								"Channel names; defaults to watts, heartrate, cadence, time, altitude."
							),
						]),
					],
					required: ["activityId"]
				)
			),
			ToolSchema(
				name: .intervalsFetchActivities,
				description:
					"Fetch up to 200 recorded activity summaries for a date range. Store-backed results use positive integer or lowercase 64-hex IDs and a bounded source-neutral shape; other readers may include additional source fields. If more than 200 store-backed activities match, narrow the date range.",
				parameters: objectSchema(
					properties: [
						"oldest": stringProperty("Oldest date (YYYY-MM-DD)"),
						"newest": stringProperty("Newest date (YYYY-MM-DD)"),
						"days": integerProperty(
							"Inclusive day count ending today in the athlete time zone"
						),
					],
					required: []
				)
			),
			ToolSchema(
				name: .intervalsListEvents,
				description:
					"List scheduled calendar workouts on intervals.icu for a date range. Use this BEFORE deleting so you can show the athlete the list (id, date, name) and ask which one to delete. Filters to WORKOUT category only. Each row carries a coachCreated flag; only coach-created workouts can be deleted with intervals_delete_workout. Pass coachCreatedOnly: true to return only coach-created events.",
				parameters: objectSchema(
					properties: [
						"oldest": stringProperty("Oldest date (YYYY-MM-DD)"),
						"newest": stringProperty("Newest date (YYYY-MM-DD)"),
						"coachCreatedOnly": .object([
							"type": .string("boolean"),
							"description": .string("Return only events created by this coach"),
						]),
					],
					required: ["oldest"]
				)
			),
			ToolSchema(
				name: .intervalsCreateWorkout,
				description:
					"Call this only when the current message explicitly asks for it. Create a structured workout on the intervals.icu calendar. Past dates are refused — workouts can only be created for today or later.",
				parameters: objectSchema(
					properties: [
						"date": stringProperty("Workout date (YYYY-MM-DD)"),
						"workout": .object([
							"type": .string("object"),
							"description": .string("Structured workout with name and steps"),
						]),
					],
					required: ["date", "workout"]
				)
			),
			ToolSchema(
				name: .intervalsCreateStrengthWorkout,
				description:
					"Create a strength/gym session on the intervals.icu calendar. Past dates are refused — sessions can only be created for today or later.",
				parameters: objectSchema(
					properties: [
						"date": stringProperty("Session date (YYYY-MM-DD)"),
						"name": stringProperty("Calendar card title"),
						"description": stringProperty("Free-text session content"),
					],
					required: ["date", "name", "description"]
				)
			),
			ToolSchema(
				name: .intervalsDeleteWorkout,
				description:
					"List and confirm first. Delete a today-or-future coach-owned workout by event ID.",
				parameters: objectSchema(
					properties: [
						"eventId": integerProperty("Event ID from intervals_list_events")
					],
					required: ["eventId"]
				)
			),
			ToolSchema(
				name: .intervalsUpdateWorkout,
				description:
					"Update a today-or-future coach-owned workout by event ID.",
				parameters: objectSchema(
					properties: [
						"eventId": integerProperty("Event ID from intervals_list_events"),
						"date": stringProperty("New workout date (YYYY-MM-DD)"),
						"name": stringProperty("New calendar title"),
						"description": stringProperty("New description"),
					],
					required: ["eventId"]
				)
			),
		]
		if shouldOfferMemoryRead(memory) {
			schemas.append(
				ToolSchema(
					name: .memoryRead,
					description:
						"Read only stored sections that Athlete Context does not show, plus today's notes and plan state.",
					parameters: objectSchema(properties: [:], required: [])
				)
			)
		}
		let sectionNames = SectionName.cyclingEffective.map(\.rawValue) + memory.orphanNames
		let uniqueSections = uniqueStrings(sectionNames)
		let sectionList = uniqueSections.map { name in
			let hint = SectionName(rawValue: name).hint
			return "\(name) (\(hint))"
		}.joined(separator: "; ")
		schemas.append(
			ToolSchema(
				name: .memoryQuery,
				description:
					"Query dated athlete memory: daily notes, the event ledger, and section history over a date range. "
					+ "Use this for any question about past notes, decisions, overrides, illness, or "
					+ "experiments. Returns matching notes, events, and history grouped by date.",
				parameters: objectSchema(
					properties: [
						"from": stringProperty("Start date (inclusive), YYYY-MM-DD"),
						"to": stringProperty("End date (inclusive), YYYY-MM-DD"),
						"query": stringProperty(
							"Case-insensitive substring filter. Omit to return everything in the range."
						),
					],
					required: ["from", "to"]
				)
			)
		)
		schemas.append(
			ToolSchema(
				name: .memoryWrite,
				description:
					"Write to long-term memory (replaces section content) or daily notes. "
					+ "Sections: \(sectionList).",
				parameters: objectSchema(
					properties: [
						"type": .object([
							"type": .string("string"),
							"enum": .array([.string("memory"), .string("daily")]),
							"description": .string(
								"'memory' for long-term facts, 'daily' for today's notes"),
						]),
						"section": .object([
							"type": .string("string"),
							"enum": .array(uniqueSections.map { .string($0) }),
							"description": .string(
								"Memory section to write to. REQUIRED when type='memory' — the write replaces the section content."
							),
						]),
						"content": stringProperty("The information to save"),
					],
					required: ["type", "content"]
				)
			)
		)
		schemas.append(
			ToolSchema(
				name: .ledgerAppend,
				description:
					"Record a dated event the athlete just stated: decision, override, illness, experiment, outcome. Skip routine training data and anything already in Athlete Context.",
				parameters: objectSchema(
					properties: [
						"date": stringProperty("Event date, YYYY-MM-DD, athlete-local"),
						"kind": .object([
							"type": .string("string"),
							"enum": .array(LedgerKind.allCases.map { .string($0.rawValue) }),
							"description": .string("Event category"),
						]),
						"text": stringProperty(
							"One or two sentences, with rationale or outcome when stated"),
					],
					required: ["date", "kind", "text"]
				)
			)
		)
		return schemas
	}
}
