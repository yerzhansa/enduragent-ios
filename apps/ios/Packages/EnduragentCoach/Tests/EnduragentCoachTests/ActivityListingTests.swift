import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct ActivityListingTests {
	static let ride = Activity.recorded("i1234567", "Sunday long ride", on: "1998-06-07")

	@Test func countsAddUpToEveryRowTheSourceReturned() throws {
		let range = try ReadRange(oldest: "1998-06-01", newest: "1998-06-13", today: "1998-06-13")
		let listing = ActivityListing(
			range: range,
			rows: [
				.hiddenByStrava, .activity(Self.ride), .unreadable, .hiddenByStrava,
				.activity(.recorded("i1234568", nil, on: "1998-06-09")), .unreadable, .unreadable,
			])
		#expect(listing.activities.map(\.id.rawValue) == ["i1234568", "i1234567"])
		#expect(listing.hiddenByStrava == 2)
		#expect(listing.unreadable == 3)
		#expect(listing.total == 7)
		#expect(listing.range == range)
		let empty = ActivityListing(range: range, rows: [])
		#expect(empty.activities.isEmpty)
		#expect(empty.total == 0)
	}

	@Test func activitiesAreOrderedNewestStartFirstThenByIdentifier() throws {
		let range = try ReadRange(oldest: "1998-06-01", newest: "1998-06-13", today: "1998-06-13")
		let listing = ActivityListing(
			range: range,
			rows: [
				Activity.recorded("i5", "Late", on: "1998-06-10", at: 18 * 3_600),
				.recorded("i4", "Same start, later identifier", on: "1998-06-10", at: 7 * 3_600),
				.recorded("i3", "Same start", on: "1998-06-10", at: 7 * 3_600),
				.recorded("i2", "No time of day", on: "1998-06-10"),
				.recorded("i9", "Day before", on: "1998-06-09", at: 23 * 3_600),
			].map(ActivityRow.activity))
		#expect(listing.activities.map(\.id.rawValue) == ["i5", "i3", "i4", "i2", "i9"])
	}

	@Test(arguments: [-1, 86_400])
	func startRefusesASecondOutsideTheDay(second: Int) {
		#expect(LocalStart(date: "1998-06-10", secondOfDay: second) == nil)
		#expect(LocalStart(date: "1998-06-10", secondOfDay: 86_399)?.secondOfDay == 86_399)
		#expect(LocalStart(date: "1998-06-10", secondOfDay: 0)?.secondOfDay == 0)
	}

	@Test(arguments: ["", "i", "٣٤٥", "½", "I123", "i12a", "12 3", "-5"])
	func identifierThatIsNotOneOfTheThreeFormsIsRefused(raw: String) {
		#expect(ActivityID(rawValue: raw) == nil)
	}

	@Test(arguments: [
		"17654321", "i1234567", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	])
	func identifierInOneOfTheThreeFormsIsKeptAsGiven(raw: String) {
		#expect(ActivityID(rawValue: raw)?.rawValue == raw)
	}
}
