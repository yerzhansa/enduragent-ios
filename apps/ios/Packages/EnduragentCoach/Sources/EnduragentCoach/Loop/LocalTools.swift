import Foundation

extension CoachTools {
	static let calculateZones = CoachTool.local(
		.read(.calculateZones),
		"Calculate power-zone watt ranges from FTP watts (7-zone numbering)",
		parameters: ToolParameters.object(
			properties: [
				"ftpWatts": ToolParameters.integer("FTP in watts", minimum: 50, maximum: 600)
			],
			required: ["ftpWatts"]
		),
		rerunWith: nil
	) { arguments, _ in
		let rows = try DisplayZones.table(ftpWatts: try arguments.ftpWatts())
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

	static let memoryRead = CoachTool.hiddenMemory(
		.memoryRead,
		"Read only stored sections that Athlete Context does not show, plus today's notes and plan state.",
		parameters: ToolParameters.none, rerunWith: nil
	) { _, reach in
		let text = try await reach.memory.complementContext(for: reach.account)
		if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return .result(.string("Every stored section is already in your Athlete Context."))
		}
		return .result(.string(text))
	}

	static let memoryQuery = CoachTool.local(
		.memoryRead(.memoryQuery),
		"Query dated athlete memory: daily notes, the event ledger, and section history over a date range. "
			+ "Use this for any question about past notes, decisions, overrides, illness, or "
			+ "experiments. Returns matching notes, events, and history grouped by date.",
		parameters: ToolParameters.object(
			properties: [
				"from": ToolParameters.string("Start date (inclusive), YYYY-MM-DD"),
				"to": ToolParameters.string("End date (inclusive), YYYY-MM-DD"),
				"query": ToolParameters.string(
					"Case-insensitive substring filter. Omit to return everything in the range."
				),
			],
			required: ["from", "to"]
		),
		rerunWith: "a shorter from/to range or a query filter"
	) { arguments, reach in
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
			let hits = try await reach.memory.query(
				from: from, to: to, contains: query, for: reach.account)
			return .result(.string(MemoryQuery.render(hits, from: from, to: to, query: query)))
		} catch let failure as MemoryQueryFailure {
			return .result(.string(failure.message))
		}
	}

	static let planLoad = CoachTool.local(
		.memoryRead(.planLoad), "Load the current active training plan",
		parameters: PlanToolSchemas.planLoad, rerunWith: nil
	) { _, reach in
		.result(try await reach.memory.savedPlans(for: reach.account).loadResult)
	}

	static let memoryWrite = CoachTool.local(
		.write(.memoryWrite), rerunWith: nil,
		describe: { memory in
			let sections = memory.writableSections
			let sectionList = sections.map { name in
				"\(name) (\(SectionName(rawValue: name).hint))"
			}.joined(separator: "; ")
			return (
				"Write to long-term memory (replaces section content) or daily notes. "
					+ "Sections: \(sectionList).",
				ToolParameters.object(
					properties: [
						"type": .object([
							"type": .string("string"),
							"enum": .array([.string("memory"), .string("daily")]),
							"description": .string(
								"'memory' for long-term facts, 'daily' for today's notes"),
						]),
						"section": .object([
							"type": .string("string"),
							"enum": .array(sections.map { .string($0) }),
							"description": .string(
								"Memory section to write to. REQUIRED when type='memory' — the write replaces the section content."
							),
						]),
						"content": ToolParameters.string("The information to save"),
					],
					required: ["type", "content"]
				)
			)
		},
		run: { arguments, reach in
			try await reach.memory.executeMemoryWrite(
				arguments, source: .chat, stamp: reach.scope.stamp)
		}
	)

	static let ledgerAppend = CoachTool.local(
		.write(.ledgerAppend),
		"Record a dated event the athlete just stated: decision, override, illness, experiment, outcome. Skip routine training data and anything already in Athlete Context.",
		parameters: ToolParameters.object(
			properties: [
				"date": ToolParameters.string("Event date, YYYY-MM-DD, athlete-local"),
				"kind": .object([
					"type": .string("string"),
					"enum": .array(LedgerKind.allCases.map { .string($0.rawValue) }),
					"description": .string("Event category"),
				]),
				"text": ToolParameters.string(
					"One or two sentences, with rationale or outcome when stated"),
			],
			required: ["date", "kind", "text"]
		),
		rerunWith: nil
	) { arguments, reach in
		try await reach.memory.executeLedgerAppend(
			arguments, source: .chat, stamp: reach.scope.stamp)
	}
}

extension LocalReach {
	fileprivate var memory: Memory {
		Memory(ledger: ledger, clock: clock)
	}

	fileprivate var account: TrainingAccount {
		scope.stamp.binding.account
	}
}

extension MemoryView {
	var hidesStoredContent: Bool {
		SectionName.cyclingEffective.contains { name in
			guard !name.inject, let stamped = sections[name.rawValue],
				let newline = stamped.firstIndex(of: "\n")
			else { return false }
			return !stamped[stamped.index(after: newline)...]
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.isEmpty
		}
	}

	fileprivate var writableSections: [String] {
		var seen: Set<String> = []
		return (SectionName.cyclingEffective.map(\.rawValue) + orphanNames).filter {
			seen.insert($0).inserted
		}
	}
}

extension JSONValue {
	fileprivate func ftpWatts() throws(ToolInputError) -> Int {
		guard let ftp = objectFields["ftpWatts"]?.intValue() else {
			throw ToolInputError(code: "invalid_ftp", details: "ftpWatts is required.")
		}
		return ftp
	}
}
