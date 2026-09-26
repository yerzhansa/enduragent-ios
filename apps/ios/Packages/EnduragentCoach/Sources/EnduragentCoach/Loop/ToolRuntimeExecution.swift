import Foundation

extension ToolRuntime {
	func executeGated(
		_ gated: GatedToolName,
		arguments: JSONValue,
		chatId: ChatID
	) async throws -> ToolOutcome {
		if gated == .planSave {
			return .result(
				UntrustedEnvelope.wrap(
					.object([
						"error": .string("not_implemented"),
						"details": .string("Saving a plan is not available yet."),
					])
				)
			)
		}
		do {
			let parsed = try parseGated(gated, arguments: arguments)
			let proposal = try await ProposalPolicy.propose(
				chatId: chatId,
				tool: gated,
				input: parsed.input,
				summary: parsed.summary,
				description: parsed.description,
				now: clock.now,
				store: store,
				clock: clock
			)
			return .pending(proposal)
		} catch let error as IntervalsError {
			return .result(UntrustedEnvelope.wrap(error.json))
		} catch let error as InvalidWorkout {
			return .result(
				UntrustedEnvelope.wrap(
					.object([
						"error": .string("invalid_workout"),
						"details": .string(error.message),
					])
				)
			)
		}
	}

	func parseGated(
		_ gated: GatedToolName,
		arguments: JSONValue
	) throws -> (input: GatedToolInput, summary: String, description: String) {
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		switch gated {
		case .intervalsCreateWorkout:
			let parsed = try CyclingTools.parseCreateWorkoutInput(arguments, today: today)
			let input = GatedToolInput.createWorkout(date: parsed.date, workout: parsed.workout)
			return (input, ProposalPolicy.summary(for: input), parsed.draft.description)
		case .intervalsCreateStrengthWorkout:
			let parsed = try CyclingTools.parseStrengthWorkout(arguments, today: today)
			let input = GatedToolInput.createStrengthWorkout(
				date: parsed.date,
				name: parsed.name,
				description: parsed.description
			)
			return (input, ProposalPolicy.summary(for: input), parsed.description)
		case .intervalsDeleteWorkout:
			let eventId = try CyclingTools.parseDeleteWorkout(arguments)
			let input = GatedToolInput.deleteWorkout(eventId: eventId)
			return (input, ProposalPolicy.summary(for: input), "")
		case .intervalsUpdateWorkout:
			let update = try CyclingTools.parseUpdateWorkout(arguments, today: today)
			let input = GatedToolInput.updateWorkout(update)
			return (input, ProposalPolicy.summary(for: input), update.description ?? "")
		case .planSave:
			throw IntervalsError(
				code: "not_implemented", details: "Saving a plan is not available yet.")
		}
	}

	static let activityIDDescription =
		"Activity ID from intervals_fetch_activities — a positive integer or digit string, optionally i-prefixed for intervals-native activities, or a lowercase 64-hex canonical ID. Pass exactly as listed."

	func memory() -> Memory {
		Memory(store: store, clock: clock)
	}

	func executeMemoryRead() async throws -> ToolOutcome {
		let text = try await memory().complementContext()
		if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return .result(.string("Every stored section is already in your Athlete Context."))
		}
		return .result(.string(text))
	}

	func executeMemoryQuery(_ arguments: JSONValue) async throws -> ToolOutcome {
		let fields = arguments.objectFields
		let fromRaw = fields["from"]?.stringValue ?? ""
		let toRaw = fields["to"]?.stringValue ?? ""
		let query = fields["query"]?.stringValue
		guard let from = CivilDate(rawValue: fromRaw), let to = CivilDate(rawValue: toRaw) else {
			return .result(
				.string(
					"Error: \(fromRaw)..\(toRaw) contains an invalid calendar date. Use real YYYY-MM-DD dates."
				)
			)
		}
		do {
			let hits = try await memory().query(from: from, to: to, contains: query)
			return .result(.string(MemoryQuery.render(hits, from: from, to: to, query: query)))
		} catch let failure as MemoryQueryFailure {
			return .result(.string(failure.message))
		}
	}

	func executeMemoryWrite(_ arguments: JSONValue) async throws -> ToolOutcome {
		let fields = arguments.objectFields
		let type = fields["type"]?.stringValue
		let content = fields["content"]?.stringValue ?? ""
		if type == "memory" {
			guard let section = fields["section"]?.stringValue else {
				return .result(
					.object([
						"details": .string(
							"type='memory' requires a section. Pick one of the listed sections, or use type='daily' for free-form notes."
						),
						"error": .string("section_required"),
					])
				)
			}
			let allowed = Set(
				SectionName.cyclingEffective.map(\.rawValue)
					+ (try await memory().view()).orphanNames)
			if !allowed.contains(section) {
				return .result(
					.object([
						"details": .string("Unknown memory section."),
						"error": .string("unknown_section"),
					])
				)
			}
			try await memory().writeSection(
				SectionName(rawValue: section), content: content, source: .chat)
			return .result(.object(["saved": .bool(true)]))
		}
		try await memory().appendDailyNote(content)
		return .result(.object(["saved": .bool(true)]))
	}

	func executeLedgerAppend(_ arguments: JSONValue) async throws -> ToolOutcome {
		let fields = arguments.objectFields
		guard
			let dateRaw = fields["date"]?.stringValue,
			let date = CivilDate(rawValue: dateRaw),
			let kindRaw = fields["kind"]?.stringValue,
			let kind = LedgerKind(rawValue: kindRaw),
			let text = fields["text"]?.stringValue,
			!text.isEmpty
		else {
			let dateRaw = fields["date"]?.stringValue ?? ""
			return .result(
				.string("Error: \(dateRaw) is not a real calendar date. Use YYYY-MM-DD."))
		}
		let recorded = try await memory().appendEvent(
			date: date, kind: kind, text: text, source: .chat)
		if recorded {
			return .result(.object(["recorded": .bool(true)]))
		}
		return .result(.object(["duplicate": .bool(true), "recorded": .bool(false)]))
	}

	func shouldOfferMemoryRead(_ view: MemoryView) -> Bool {
		for name in SectionName.cyclingEffective where !name.inject {
			if let content = view.sections[name.rawValue], memorySectionHasLogicalContent(content) {
				return true
			}
		}
		return false
	}

	func executeCalculateZones(_ arguments: JSONValue) throws -> ToolOutcome {
		guard let ftp = arguments.objectFields["ftpWatts"]?.intValue() else {
			throw IntervalsError(code: "invalid_ftp", details: "ftpWatts is required.")
		}
		let rows = try DisplayZones.table(ftpWatts: ftp)
		return .result(
			.array(
				rows.map { row in
					var fields: [String: JSONValue] = [
						"label": .string(row.label),
						"value": .string(row.value),
					]
					if row.overlaps {
						fields["overlaps"] = .bool(true)
					}
					return .object(fields)
				}))
	}

	func listRange(from arguments: JSONValue) throws -> (
		oldest: CivilDate, newest: CivilDate
	) {
		let fields = arguments.objectFields
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		if let oldest = try optionalDate(fields["oldest"], label: "oldest") {
			let newest = try optionalDate(fields["newest"], label: "newest") ?? today
			try IntervalsPolicy.rejectListRange(oldest: oldest, newest: newest)
			return (oldest, newest)
		}
		if let days = fields["days"]?.intValue(), days >= 1 {
			let newest = today
			let oldest = today.adding(days: -(days - 1))
			try IntervalsPolicy.rejectListRange(oldest: oldest, newest: newest)
			return (oldest, newest)
		}
		throw IntervalsError(
			code: "invalid_date",
			details: "oldest is not a real calendar date. Use YYYY-MM-DD."
		)
	}

	func optionalDate(_ value: JSONValue?, label: String) throws -> CivilDate? {
		guard let value else { return nil }
		guard let raw = value.stringValue else {
			throw IntervalsError(
				code: "invalid_date",
				details: "\(label) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		guard let date = CivilDate(rawValue: raw) else {
			throw IntervalsError(
				code: "invalid_date",
				details: "\(raw) is not a real calendar date. Use YYYY-MM-DD."
			)
		}
		return date
	}

	func activityID(from arguments: JSONValue) throws -> ActivityID {
		let value = arguments.objectFields["activityId"]
		if let raw = value?.stringValue, let id = ActivityID(rawValue: raw) {
			return id
		}
		if let number = value?.intValue(), let id = ActivityID(rawValue: String(number)) {
			return id
		}
		throw IntervalsError(
			code: "invalid_input",
			details: "activityId must be a positive integer, i-prefixed id, or lowercase 64-hex id."
		)
	}

	func encodeAthlete(_ profile: AthleteProfile) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .string(profile.id),
			"name": .string(profile.name),
		]
		if let ftp = profile.ftp {
			fields["ftp"] = .number(Double(ftp))
		}
		return .object(fields)
	}

	func encodeWellness(_ day: WellnessDay) -> JSONValue {
		var fields: [String: JSONValue] = ["date": .string(day.date.rawValue)]
		if let fitness = day.fitness { fields["fitness"] = .number(fitness) }
		if let fatigue = day.fatigue { fields["fatigue"] = .number(fatigue) }
		if let form = day.form { fields["form"] = .number(form) }
		return .object(fields)
	}

	func encodeActivity(_ row: ActivitySummary) -> JSONValue {
		var fields: [String: JSONValue] = [
			"name": .string(row.name),
			"date": .string(row.date.rawValue),
			"durationS": .number(Double(row.durationS)),
		]
		if let load = row.trainingLoad {
			fields["trainingLoad"] = .number(Double(load))
		}
		return .object(fields)
	}

	func encodeEvent(_ event: CalendarEvent) -> JSONValue {
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

	func objectSchema(properties: [String: JSONValue], required: [String]) -> JSONValue {
		var fields: [String: JSONValue] = [
			"type": .string("object"),
			"properties": .object(properties),
		]
		if !required.isEmpty {
			fields["required"] = .array(required.map { .string($0) })
		}
		return .object(fields)
	}

	func stringProperty(_ description: String) -> JSONValue {
		.object([
			"type": .string("string"),
			"description": .string(description),
		])
	}

	func uniqueStrings(_ values: [String]) -> [String] {
		var seen: Set<String> = []
		var unique: [String] = []
		for value in values where seen.insert(value).inserted {
			unique.append(value)
		}
		return unique
	}

	func memorySectionHasLogicalContent(_ stamped: String) -> Bool {
		guard let newline = stamped.firstIndex(of: "\n") else { return false }
		return !stamped[stamped.index(after: newline)...]
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty
	}

	func integerProperty(_ description: String, minimum: Int? = nil, maximum: Int? = nil)
		-> JSONValue
	{
		var fields: [String: JSONValue] = [
			"type": .string("integer"),
			"description": .string(description),
		]
		if let minimum {
			fields["minimum"] = .number(Double(minimum))
		}
		if let maximum {
			fields["maximum"] = .number(Double(maximum))
		}
		return .object(fields)
	}
}
