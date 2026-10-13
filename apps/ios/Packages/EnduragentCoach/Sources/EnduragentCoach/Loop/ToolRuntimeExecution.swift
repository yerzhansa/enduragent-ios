import Foundation

extension ToolRuntime {
	func executeGated(
		_ gated: GatedToolName,
		arguments: JSONValue,
		chatId: ChatID,
		scope: TurnScope
	) async throws -> ToolOutcome {
		do {
			let parsed = try parseGated(gated, arguments: arguments)
			let proposal = try await reviews.propose(
				chatId: chatId,
				tool: gated,
				input: parsed.input,
				summary: parsed.summary,
				description: parsed.description,
				scope: scope
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

	private func parseGated(
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

	func memory() -> Memory {
		Memory(ledger: ledger, clock: clock)
	}

	func executeMemoryRead(for account: TrainingAccount) async throws -> ToolExecution {
		let text = try await memory().complementContext(for: account)
		if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return .result(.string("Every stored section is already in your Athlete Context."))
		}
		return .result(.string(text))
	}

	func executeMemoryQuery(_ arguments: JSONValue, for account: TrainingAccount) async throws
		-> ToolExecution
	{
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
			let hits = try await memory().query(from: from, to: to, contains: query, for: account)
			return .result(.string(MemoryQuery.render(hits, from: from, to: to, query: query)))
		} catch let failure as MemoryQueryFailure {
			return .result(.string(failure.message))
		}
	}

	func executeCalculateZones(_ arguments: JSONValue) throws -> ToolExecution {
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
		switch profile.ftp {
		case .usable(let watts):
			fields["ftp"] = .number(watts.value)
		case .implausible(let reported?):
			fields["ftp"] = .number(reported)
		case .absent, .implausible(nil):
			break
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
}

extension JSONValue {
	func readRange(today: CivilDate) throws(IntervalsError) -> ReadRange {
		let fields = objectFields
		if let oldest = try Self.optionalDate(fields["oldest"], label: "oldest") {
			return try ReadRange(
				oldest: oldest, newest: try Self.optionalDate(fields["newest"], label: "newest"),
				today: today)
		}
		if let value = fields["days"] {
			guard let days = value.intValue() else {
				throw IntervalsError(
					code: "invalid_input", details: "days must be a positive integer.")
			}
			return try ReadRange(endingOn: today, days: days)
		}
		throw IntervalsError(
			code: "invalid_date",
			details: "oldest is not a real calendar date. Use YYYY-MM-DD."
		)
	}

	private static func optionalDate(_ value: JSONValue?, label: String) throws(IntervalsError)
		-> CivilDate?
	{
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
}
