import Testing

@testable import EnduragentCoach

@Suite struct CivilDateValidationTests {
	@Test(arguments: [
		"1583-01-01", "1600-02-29",
		"1900-02-28", "1996-02-29", "2000-02-29", "2024-02-29", "2024-04-30",
		"2024-01-31", "2100-02-28", "2400-02-29", "9999-12-31",
	])
	func acceptsCanonicalGregorianDates(key: String) {
		#expect(CivilDate.isRealDateKey(key))
		#expect(CivilDate(rawValue: key)?.rawValue == key)
	}

	@Test(arguments: [
		"0001-01-01", "0004-02-29", "0400-02-29", "1500-02-28", "1582-06-15", "1582-10-10",
	])
	func rejectsDatesBeforeGregorianArithmetic(key: String) {
		#expect(!CivilDate.isRealDateKey(key))
		#expect(CivilDate(rawValue: key) == nil)
	}

	@Test(arguments: [
		"", " ", "2024-1-1", "2024-01-1", "2024-1-01", "24-01-01",
		"2024/01/01", "2024.01.01", "2024 01 01", "2024_01_01",
		" 2024-01-01", "2024-01-01 ", "\t2024-01-01\n", "2024- 1- 1",
		"２０２４-０１-０１", "٢٠٢٤-٠١-٠١", "२०२४-०१-०१", "2024-０1-01",
		"2024-01-01x", "2024-01-01T00:00:00Z", "2024-01-01\0",
		"20240101", "2024--01-01", "2024-01", "2024-01-", "2024-01-001",
		"+2024-01-01", "-2024-01-01", "02024-01-01", "10000-01-01",
		"202A-01-01", "2024-0A-01", "2024-01-0A", "2024-00-10", "2024-13-10",
		"2024-02-30", "2023-02-29", "2024-04-31", "2024-01-00", "2024-01-32",
		"0000-01-01", "0100-02-29", "1500-02-29", "1900-02-29", "2100-02-29",
	])
	func rejectsNoncanonicalOrImpossibleDates(key: String) {
		#expect(!CivilDate.isRealDateKey(key))
		#expect(CivilDate(rawValue: key) == nil)
	}
}
