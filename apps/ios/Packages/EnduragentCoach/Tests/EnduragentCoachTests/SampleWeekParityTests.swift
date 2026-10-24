import Testing

@testable import EnduragentCoach

@Suite struct SampleWeekParityTests {
	@Test func everyRecordedRequestGetsNpmsSampleWeek() throws {
		let cases = try PlanFixtures.cases("sample-week")
		var compared = 0
		var mismatched: [String] = []
		var lowSixFlexible: [Int] = []
		for item in cases {
			compared += 1
			let request: SampleWeekRequest
			do {
				request = try PlanningArguments.sampleWeek(item.input)
			} catch {
				mismatched.append("\(item.id) refused: \(error.details)")
				continue
			}
			let week = Planning.sampleWeek(request)
			guard week.json == item.output else {
				mismatched.append(item.id)
				continue
			}
			if request.tier == .low, request.scheduleType == .flexible,
				request.sessionsPerWeek == 6
			{
				lowSixFlexible.append(week.sessions.count)
			}
		}
		#expect(
			mismatched.isEmpty,
			"\(mismatched.count) cases differ from npm, first: \(mismatched.prefix(3))")
		#expect(lowSixFlexible == [3])
		#expect(compared == (try PlanFixtures.manifestCount(["sample-week"])))
		#expect(compared > 0)
	}
}
