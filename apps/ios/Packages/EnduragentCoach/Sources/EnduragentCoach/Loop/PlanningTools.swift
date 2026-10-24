extension CoachTools {
	static let assessFeasibility = CoachTool.local(
		.read(.assessFeasibility),
		"Assess whether an FTP or W/kg target is realistic given current fitness and experience level",
		parameters: PlanToolSchemas.assessFeasibility,
		rerunWith: nil
	) { arguments, _ in
		let goal = try PlanningArguments.feasibility(arguments)
		return .result(Planning.feasibility(goal)?.json ?? PlanningArguments.achievable)
	}

	static let buildPlanSkeleton = CoachTool.local(
		.read(.buildPlanSkeleton),
		prescriptionSelectionRule
			+ " Build a periodized training plan skeleton from athlete profile. Returns phases, volume targets, zone tables, and testing protocols. Does NOT save anything — present the skeleton to the athlete and call plan_save only after they approve.",
		parameters: PlanToolSchemas.buildPlanSkeleton,
		rerunWith: nil
	) { arguments, reach in
		let profile = try PlanningArguments.profile(arguments)
		let options = PlanDraftOptions(
			id: await reach.ledger.nextULID().rawValue,
			createdAt: GregorianStamp.isoMillis(reach.clock.now), totalWeeks: nil)
		return .result(try Planning.draft(profile, today: reach.today, options: options).json)
	}

	static let getSampleWeek = CoachTool.local(
		.read(.getSampleWeek),
		prescriptionSelectionRule
			+ " Get a sample training week for a given volume tier and schedule type",
		parameters: PlanToolSchemas.getSampleWeek,
		rerunWith: nil
	) { arguments, _ in
		.result(Planning.sampleWeek(try PlanningArguments.sampleWeek(arguments)).json)
	}

	private static let prescriptionSelectionRule =
		"Call this only when the current message explicitly asks for it; see the Cycling Prescription Availability skill."
}

extension PlanningArguments {
	static let achievable = JSONValue.object([
		"message": .string("Goal appears achievable within one plan cycle.")
	])
}
