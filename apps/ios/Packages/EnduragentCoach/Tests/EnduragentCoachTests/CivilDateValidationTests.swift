import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CivilDateValidationTests {
	@Test func matchesFormatterForEveryDayAndMonthBoundaryFrom1900Through2100() {
		let oracle = dateFormatterOracle()
		var accepted = 0
		var rejected = 0
		for year in 1900...2100 {
			for month in 1...12 {
				for day in 0...32 {
					let key = String(format: "%04d-%02d-%02d", year, month, day)
					let expected = oracle.date(from: key) != nil
					#expect(CivilDate.isRealDateKey(key) == expected, "\(key)")
					#expect((CivilDate(rawValue: key) != nil) == expected, "\(key)")
					if expected {
						accepted += 1
					} else {
						rejected += 1
					}
				}
			}
		}
		#expect(accepted == 73_414)
		#expect(rejected == 6_182)
		Attachment.record(
			"\(accepted) valid days; \(rejected) invalid days; 1900...2100, months 1...12, days 0...32",
			named: "civil-date-oracle-coverage.txt")
	}

	@Test func matchesFormatterOutsideModernCanonicalDates() {
		let oracle = dateFormatterOracle()
		let years = [0, 1, 4, 100, 400, 1500, 1582, 1583, 1600, 1700, 1800, 2101, 2400, 9999]
		for year in years {
			for month in 0...13 {
				for day in 0...32 {
					let key = String(format: "%04d-%02d-%02d", year, month, day)
					let expected = oracle.date(from: key) != nil
					#expect(CivilDate.isRealDateKey(key) == expected, "\(key)")
					#expect((CivilDate(rawValue: key) != nil) == expected, "\(key)")
				}
			}
		}
		let keys = [
			"", " ", "2024-1-1", "2024-01-1", "2024-1-01", "24-01-01",
			"2024/01/01", "2024.01.01", "2024 01 01", "2024_01_01",
			" 2024-01-01", "2024-01-01 ", "\t2024-01-01\n", "2024- 1- 1",
			"２０２４-０１-０１", "٢٠٢٤-٠١-٠١", "२०२४-०१-०१", "2024-０1-01",
			"2024-01-01x", "2024-01-01T00:00:00Z", "2024-01-01\0",
			"20240101", "2024--01-01", "2024-01", "2024-01-", "2024-01-001",
			"+2024-01-01", "-2024-01-01", "02024-01-01", "10000-01-01",
			"202A-01-01", "2024-0A-01", "2024-01-0A", "2024-00-10", "2024-13-10",
			"2024-02-30", "2023-02-29", "2024-04-31", "2024-01-00", "2024-01-32",
		]
		for key in keys {
			let expected = oracle.date(from: key) != nil
			#expect(CivilDate.isRealDateKey(key) == expected, "\(key.debugDescription)")
			#expect((CivilDate(rawValue: key) != nil) == expected, "\(key.debugDescription)")
		}
		Attachment.record(
			"\(years.count * 14 * 33) historical and boundary keys; \(keys.count) noncanonical and malformed keys",
			named: "civil-date-fallback-coverage.txt")
	}

	@Test(arguments: [1900, 1996, 2000, 2004, 2096, 2100])
	func february29ObeysGregorianLeapYears(year: Int) {
		let key = String(format: "%04d-02-29", year)
		let expected = [1996, 2000, 2004, 2096].contains(year)
		#expect(CivilDate.isRealDateKey(key) == expected)
		#expect((CivilDate(rawValue: key) != nil) == expected)
	}

	private func dateFormatterOracle() -> DateFormatter {
		let oracle = DateFormatter()
		oracle.calendar = Calendar(identifier: .gregorian)
		oracle.locale = Locale(identifier: "en_US_POSIX")
		oracle.timeZone = TimeZone(secondsFromGMT: 0)
		oracle.dateFormat = "yyyy-MM-dd"
		oracle.isLenient = false
		return oracle
	}
}
