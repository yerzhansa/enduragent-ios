import Testing

@testable import EnduragentCoach

@Suite struct FeasibilityParityTests {
	@Test func everyRecordedGoalGetsNpmsFeasibilityCheck() throws {
		let cases = try PlanFixtures.cases("feasibility")
		var compared = 0
		var mismatched: [String] = []
		var severities: Set<String> = []
		for item in cases {
			compared += 1
			let output: JSONValue
			do {
				output =
					try Planning.feasibility(PlanningArguments.feasibility(item.input))?.json
					?? .null
			} catch {
				mismatched.append("\(item.id) refused: \(error.details)")
				continue
			}
			guard output == item.output else {
				mismatched.append(item.id)
				continue
			}
			if let severity = output.objectFields["severity"]?.stringValue {
				severities.insert(severity)
			}
		}
		#expect(
			mismatched.isEmpty,
			"\(mismatched.count) cases differ from npm, first: \(mismatched.prefix(3))")
		#expect(severities == ["warning", "ambitious"])
		#expect(compared == (try PlanFixtures.manifestCount(["feasibility"])))
		#expect(compared > 0)
	}
}
