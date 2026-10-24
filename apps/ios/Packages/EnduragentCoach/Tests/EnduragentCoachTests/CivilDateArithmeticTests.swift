import Testing

@testable import EnduragentCoach

@Suite struct CivilDateArithmeticTests {
	@Test(
		arguments: [
			("1583-01-01", .sat), ("1899-12-31", .sun), ("1900-01-01", .mon),
			("1900-02-28", .wed), ("1900-03-01", .thu), ("1970-01-01", .thu),
			("1999-12-31", .fri), ("2000-01-01", .sat), ("2000-02-28", .mon),
			("2000-02-29", .tue), ("2000-03-01", .wed), ("2023-12-31", .sun),
			("2024-01-01", .mon), ("2024-02-29", .thu), ("2100-02-28", .sun),
			("2100-03-01", .mon), ("9999-12-31", .fri),
		] as [(CivilDate, Weekday)]
	)
	func weekdayIsTheGregorianWeekday(day: CivilDate, weekday: Weekday) {
		#expect(day.weekday == weekday)
	}

	@Test(
		arguments: [
			("1900-02-28", "1900-03-01", 1), ("1900-03-01", "1900-02-28", -1),
			("2000-02-28", "2000-03-01", 2), ("2000-03-01", "2000-02-28", -2),
			("2000-02-29", "2000-03-01", 1), ("2100-02-28", "2100-03-01", 1),
			("1999-12-31", "2000-01-01", 1), ("2023-12-31", "2024-01-01", 1),
			("2024-01-01", "2023-12-31", -1), ("2024-02-29", "2024-02-29", 0),
			("1900-02-28", "2000-03-01", 36526), ("2000-03-01", "1900-02-28", -36526),
			("1999-12-31", "2024-02-29", 8826), ("1583-01-01", "9999-12-31", 3_074_245),
			("9999-12-31", "1583-01-01", -3_074_245),
		] as [(CivilDate, CivilDate, Int)]
	)
	func dayCountIsSignedAndAddingItReachesTheOtherDay(
		from start: CivilDate, to end: CivilDate, days: Int
	) {
		#expect(start.days(until: end) == days)
		#expect(start.adding(days: start.days(until: end)) == end)
	}

	@Test func weekdayOfEveryRecordedTodayIsNpmsWeekday() throws {
		let files = ["total-weeks"] + (try PlanFixtures.planDraftFiles())
		var compared = 0
		for file in files {
			for item in try PlanFixtures.cases(file) {
				let today = try #require(item.today, "\(item.id) records no today")
				let recorded = try #require(
					item.weekday.flatMap(Weekday.init(rawValue:)),
					"\(item.id) records no weekday")
				#expect(today.weekday == recorded, "\(item.id) on \(today)")
				compared += 1
			}
		}
		#expect(compared == (try PlanFixtures.manifestCount(files)))
		#expect(compared > 0)
	}
}
