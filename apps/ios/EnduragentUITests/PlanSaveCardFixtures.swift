import EnduragentCoach

enum PlanCardSize: String {
	case standard
	case largest

	var textSize: FixtureTextSize? {
		switch self {
		case .standard: nil
		case .largest: .accessibilityXXXL
		}
	}
}

struct PlanFixture {
	struct Phase {
		var focus: CatalogKey?
		var weeks: Int?
		var hours: Bool
	}

	var name: String
	var goal: String?
	var weeks: Int?
	var phases: [Phase]

	static let directive = "fixture:plan-save"
	static let longDirective = "fixture:plan-save-long"
	static let notPreparedDirective = "fixture:plan-save-not-prepared"
	static let reply = "Your plan is ready."
	static let laterClock = "1998-06-15T08:11:00Z"

	static func directive(weeks: Int) -> String {
		"\(directive) \(weeks)"
	}

	static func weeks(_ weeks: Int) -> PlanFixture {
		let build = (weeks - 2) / 2
		return PlanFixture(
			name: "\(weeks)-Week Gran Fondo Plan", goal: "Finish the June gran fondo",
			weeks: weeks,
			phases: [
				Phase(
					focus: Catalog.chatPlanSaveFocusBaseBuilding, weeks: weeks - 2 - build,
					hours: true),
				Phase(focus: Catalog.chatPlanSaveFocusThreshold, weeks: build, hours: true),
				Phase(focus: Catalog.chatPlanSaveFocusTaper, weeks: 2, hours: true),
			])
	}

	static let long = PlanFixture(
		name:
			"Dolomites Gran Fondo Endurance and Climbing Preparation Plan for the Long June Weekend",
		goal:
			"Ride the full 170 km route with 4,000 m of climbing and finish strong on the last pass",
		weeks: 16,
		phases: [
			Phase(focus: Catalog.chatPlanSaveFocusAerobicDevelopment, weeks: 5, hours: true),
			Phase(focus: Catalog.chatPlanSaveFocusThreshold, weeks: 5, hours: true),
			Phase(focus: Catalog.chatPlanSaveFocusRacePrep, weeks: 4, hours: true),
			Phase(focus: Catalog.chatPlanSaveFocusTaper, weeks: 2, hours: true),
		])
}
