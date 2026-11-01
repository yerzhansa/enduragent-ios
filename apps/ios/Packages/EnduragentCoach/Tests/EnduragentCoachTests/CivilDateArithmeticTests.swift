import Foundation
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

	@Test func dayArithmeticFrom1583IsFoundationsGregorianCalendar() throws {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		let start: CivilDate = "1583-01-01"
		let origin = try #require(calendar.date(from: DateComponents(year: 1583, month: 1, day: 1)))
		func offset(_ year: Int, _ month: Int, _ day: Int) throws -> Int {
			let date = try #require(
				calendar.date(from: DateComponents(year: year, month: month, day: day)))
			return try #require(calendar.dateComponents([.day], from: origin, to: date).day)
		}
		let last = try offset(9999, 12, 31)
		let wholeYears = [1583, 1600, 1899, 1900, 1901, 1970, 2000] + Array(2024...2030) + [9999]
		var offsets = try wholeYears.flatMap { year in
			try offset(year, 1, 1)...min(try offset(year + 1, 1, 1) - 1, last)
		}
		var generator = SplitMix64(seed: 34)
		offsets += (0..<4_000).map { _ in Int.random(in: 0...last, using: &generator) }
		var mismatches: [String] = []
		for days in offsets {
			let shown = try #require(calendar.date(byAdding: .day, value: days, to: origin))
			let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: shown)
			let next = calendar.dateComponents(
				[.year, .month, .day],
				from: try #require(calendar.date(byAdding: .day, value: 1, to: shown)))
			let day = CivilDate(
				year: try #require(parts.year), month: try #require(parts.month),
				day: try #require(parts.day))
			let following = CivilDate(
				year: try #require(next.year), month: try #require(next.month),
				day: try #require(next.day))
			let weekday = Weekday.allCases[(try #require(parts.weekday) + 5) % 7]
			if start.adding(days: days) != day || start.days(until: day) != days
				|| day.adding(days: 1) != following || day.weekday != weekday
			{
				mismatches.append(day.rawValue)
			}
		}
		#expect(
			mismatches.isEmpty,
			"\(mismatches.count) of \(offsets.count) days differ, first \(mismatches.prefix(3))")
		#expect(offsets.count > 4_000)
	}

	@Test(
		arguments: [
			("0000-01-01", -719_528, .sat), ("0000-02-29", -719_469, .tue),
			("0000-03-01", -719_468, .wed), ("0000-12-31", -719_163, .sun),
			("0001-01-01", -719_162, .mon), ("0004-02-29", -718_008, .sun),
			("0100-02-28", -682_945, .sun), ("0100-03-01", -682_944, .mon),
			("0400-02-29", -573_372, .tue), ("1000-06-15", -354_120, .sun),
			("1500-02-28", -171_606, .wed), ("1500-03-01", -171_605, .thu),
			("1582-10-04", -141_438, .mon), ("1582-10-05", -141_437, .tue),
			("1582-10-10", -141_432, .sun), ("1582-10-15", -141_427, .fri),
			("1582-12-31", -141_350, .fri), ("1583-01-01", -141_349, .sat),
			("1998-06-13", 10_390, .sat),
		] as [(CivilDate, Int, Weekday)]
	)
	func daysBefore1583CountAsJavaScriptDoes(day: CivilDate, sinceEpoch: Int, weekday: Weekday) {
		let epoch: CivilDate = "1970-01-01"
		#expect(epoch.days(until: day) == sinceEpoch)
		#expect(epoch.adding(days: sinceEpoch) == day)
		#expect(day.weekday == weekday)
	}

	@Test(arguments: [0, 1, 4, 100, 400, 1500, 1582])
	func everyDayOfAnEarlyYearFollowsTheDayBefore(year: Int) throws {
		let realDays = (1...12).flatMap { month in
			(1...31).map { CivilDate(year: year, month: month, day: $0).rawValue }
		}.filter(CivilDate.isRealDateKey)
		let first = CivilDate(year: year, month: 1, day: 1)
		let walked = realDays.indices.map { first.adding(days: $0) }
		#expect(walked.map(\.rawValue) == realDays)
		#expect(first.adding(days: realDays.count) == CivilDate(year: year + 1, month: 1, day: 1))
		#expect(first.days(until: CivilDate(year: year + 1, month: 1, day: 1)) == realDays.count)
		let firstWeekday = try #require(Weekday.allCases.firstIndex(of: first.weekday))
		#expect(
			walked.enumerated().allSatisfy { index, day in
				day.weekday == Weekday.allCases[(firstWeekday + index) % 7]
			})
	}

	@Test func movingPastEitherEndOfTheRangeStillCountsBack() {
		let first: CivilDate = "0000-01-01"
		let last: CivilDate = "9999-12-31"
		#expect(last.adding(days: 1).rawValue == "10000-01-01")
		#expect(last.adding(days: 1).days(until: last) == -1)
		#expect(first.adding(days: -1).rawValue == "-001-12-31")
		#expect(first.adding(days: -1).days(until: first) == 1)
		#expect(first.adding(days: -1).weekday == .fri)
	}
}

private struct SplitMix64: RandomNumberGenerator {
	var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var mixed = state
		mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
		mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
		return mixed ^ (mixed >> 31)
	}
}
