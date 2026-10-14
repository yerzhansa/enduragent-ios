import Testing

@testable import EnduragentCoach

@Suite struct ReadRangeTests {
	@Test func reversedBoundsAreRefused() {
		#expect(throws: ReadRangeRefusal.reversed(oldest: "1998-06-14", newest: "1998-06-13")) {
			try ReadRange(oldest: "1998-06-14", newest: "1998-06-13", today: "1998-06-20")
		}
	}

	@Test func omittedNewestEndsOnToday() throws {
		let range = try ReadRange(oldest: "1998-06-07", newest: nil, today: "1998-06-13")
		#expect(range.oldest == "1998-06-07")
		#expect(range.newest == "1998-06-13")
	}

	@Test func omittedNewestBeforeOldestIsReversed() {
		#expect(throws: ReadRangeRefusal.reversed(oldest: "1998-06-14", newest: "1998-06-13")) {
			try ReadRange(oldest: "1998-06-14", newest: nil, today: "1998-06-13")
		}
	}

	@Test func exactly366InclusiveDaysAreAccepted() throws {
		let oldest: CivilDate = "1998-01-01"
		let range = try ReadRange(oldest: oldest, newest: oldest.adding(days: 365), today: oldest)
		#expect(range.newest == "1999-01-01")
	}

	@Test func aRangeOf367InclusiveDaysIsRefused() {
		let oldest: CivilDate = "1998-01-01"
		#expect(throws: ReadRangeRefusal.tooWide(days: 367)) {
			try ReadRange(oldest: oldest, newest: oldest.adding(days: 366), today: oldest)
		}
	}

	@Test func snapshotLookbackIsSevenDaysEndingOnToday() {
		let range = ReadRange.snapshotLookback(endingOn: "1998-06-13")
		#expect(range.oldest == "1998-06-07")
		#expect(range.newest == "1998-06-13")
		#expect(range.contains("1998-06-07"))
		#expect(range.contains("1998-06-13"))
		#expect(!range.contains("1998-06-06"))
		#expect(!range.contains("1998-06-14"))
	}

	@Test func oneDayCoversOnlyThatDay() {
		let range = ReadRange.day("1998-06-13")
		#expect(range.oldest == "1998-06-13")
		#expect(range.newest == "1998-06-13")
	}
}
