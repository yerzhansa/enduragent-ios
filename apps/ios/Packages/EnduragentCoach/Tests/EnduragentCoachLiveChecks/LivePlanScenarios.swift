import Foundation

@testable import EnduragentCoach

enum LivePlanScenarios {
	static let title = "Live planning suite"
	static let raceDays = 84
	static let feasibility = "I'm an intermediate rider at 200 W. Can I get to 280 W?"
	static let save = "That looks right. Save that plan."
	static let load = "What is my current plan? Load it and list its phases."
	static let revision =
		"What would a typical week with four sessions look like, and what would a 10-week version look like?"
	static let draftNumbers = ["totalWeeks", "phases.durationWeeks", "zoneTables.zones.range"]

	static let planned: LiveCoachSuite.Scenarios = { _, today in (scenarios(today: today), []) }

	static func inWords(today: CivilDate) -> String {
		"I'm an intermediate cyclist with an FTP of 250 W, and I can train about 8 hours a week on Tuesday, Thursday, Saturday and Sunday, with my long ride on Sunday. My goal is a gran fondo on \(today.adding(days: raceDays).rawValue). Show me the phases of a training plan with their weeks, and my power zones."
	}

	static func scenarios(today: CivilDate) -> [LiveScenario] {
		let inWords = inWords(today: today)
		return [
			LiveScenario(
				name: "feasibility", setting: .connected,
				turns: [
					LiveTurnPlan(
						message: feasibility,
						expectations: [
							.calls(.assessFeasibility),
							.plan(
								.keepsNumbers(
									.assessFeasibility,
									fields: [
										"gapPercentage", "realisticMilestone", "estimatedCycles",
									])),
							.plan(.leavesNoCard),
						])
				]),
			LiveScenario(
				name: "plan-without-details", setting: .connected,
				turns: [
					LiveTurnPlan(
						message: "/plan",
						expectations: [
							.neverCalls(.buildPlanSkeleton), .replyMentions(["?"]),
							.plan(.leavesNoCard),
						])
				]),
			LiveScenario(
				name: "plan-in-words", setting: .connected,
				turns: [
					LiveTurnPlan(
						message: inWords,
						expectations: [
							.calls(.buildPlanSkeleton),
							.plan(.keepsNumbers(.buildPlanSkeleton, fields: draftNumbers)),
							.neverCalls(.planSave), .plan(.claimsNoSave), .plan(.leavesNoCard),
						])
				]),
			LiveScenario(
				name: "save-and-load", setting: .connected,
				turns: [
					LiveTurnPlan(message: inWords, expectations: []),
					LiveTurnPlan(
						message: save,
						expectations: [
							.plan(.savesOnce), .plan(.savesDraft), .plan(.claimsNoSave),
							.replyMentions(["Save plan"]),
						], tapsSavePlan: true),
					LiveTurnPlan(
						message: load,
						expectations: [
							.promptHolds(SavedPlans.heading), .promptLacks(SavedPlans.noPlan),
							.plan(.loadsSaved),
						]),
					LiveTurnPlan(
						message: revision,
						expectations: [
							.calls(.getSampleWeek), .calls(.buildPlanSkeleton),
							.plan(.keepsSavedPlan),
						]),
				]),
		]
	}
}
