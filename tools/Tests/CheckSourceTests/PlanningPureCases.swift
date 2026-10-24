extension SourceCases {
	static let planning = "\(coachSources)/Planning"
	static let impurePlanningLines = [
		"let now = clock.now as any Clock",
		"let wait = ContinuousClock()",
		"let createdAt = Date()",
		"let createdAt = Date.now",
		"let id = UUID()",
		"let zone = TimeZone.current",
		"let records: Ledger",
		"actor PlanCache {}",
	]
	static let purePlanning =
		"extension Planning {\n"
		+ "\tstatic func feasibility(_ goal: FeasibilityGoal) -> FeasibilityCheck? {\n"
		+ "\t\tlet factor = log(1 + 0.25)\n"
		+ "\t\tlet day = CivilDate(rawValue: \"1970-01-01\")\n"
		+ "\t\tlet stamp = Date(timeIntervalSince1970: 0)\n"
		+ "\t\tlet zone = TimeZone(identifier: \"UTC\")\n"
		+ "\t\treturn nil\n\t}\n}\n"

	static let planningPure: [SourceCase] =
		impurePlanningLines.map { line in
			.rejects(
				"rejects \(line) under Planning", ["\(planning)/Feasibility.swift": line],
				finding: "\"\(planning)/Feasibility.swift\" [planning-pure]")
		}
		+ [
			.accepts(
				"accepts a pure planning file",
				["\(planning)/Feasibility.swift": purePlanning]),
			.accepts(
				"accepts clocks, dates, ids, ledgers and actors outside Planning",
				[
					"\(coachSources)/Coach.swift": impurePlanningLines.joined(separator: "\n"),
					"\(coachSources)/Plans/Plans.swift": impurePlanningLines.joined(
						separator: "\n"),
				]),
		]
}
