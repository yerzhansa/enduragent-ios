import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TotalWeeksParityTests {
	@Test func everyRecordedGoalGetsNpmsWeekCountOnThePhonesDay() throws {
		var compared = 0
		var mismatched: [String] = []
		var racesOnOrBeforeToday = 0
		for item in try PlanFixtures.cases("total-weeks") {
			compared += 1
			let instant = try #require(item.instant, "\(item.id) records no instant")
			let zone = try #require(item.timeZone, "\(item.id) records no time zone")
			let today = try #require(item.today, "\(item.id) records no today")
			guard IntervalsPolicy.today(now: instant, timeZone: zone) == today else {
				mismatched.append("\(item.id) is another day on the phone")
				continue
			}
			let profile: PlanProfile
			do {
				profile = try PlanningArguments.profile(item.input)
			} catch {
				mismatched.append("\(item.id) refused: \(error.details)")
				continue
			}
			let weeks = Planning.totalWeeks(profile, today: today)
			guard item.output == .number(Double(weeks)) else {
				mismatched.append(item.id)
				continue
			}
			if profile.goal.type == .race, let raceDate = profile.goal.raceDate, raceDate <= today {
				#expect(weeks == 8, "\(item.id) races on \(raceDate), today is \(today)")
				racesOnOrBeforeToday += 1
			}
		}
		#expect(
			mismatched.isEmpty,
			"\(mismatched.count) cases differ from npm, first: \(mismatched.prefix(3))")
		#expect(racesOnOrBeforeToday > 0)
		#expect(compared == (try PlanFixtures.manifestCount(["total-weeks"])))
		#expect(compared > 0)
	}
}
