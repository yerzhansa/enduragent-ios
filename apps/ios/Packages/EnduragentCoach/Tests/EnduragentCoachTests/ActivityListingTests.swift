import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct ActivityListingTests {
	static let ride = Activity.recorded("i1234567", "Sunday long ride", on: "1998-06-07")

	@Test(arguments: [
		ActivityRowCase("STRAVA", sport: nil, moving: nil, elapsed: nil, readable: true, .hiddenByStrava),
		ActivityRowCase("STRAVA", sport: nil, moving: nil, elapsed: nil, readable: false, .hiddenByStrava),
		ActivityRowCase("STRAVA", sport: nil, moving: 600, elapsed: 600, readable: true, .hiddenByStrava),
		ActivityRowCase("STRAVA", sport: "Ride", moving: nil, elapsed: 600, readable: true, .hiddenByStrava),
		ActivityRowCase("STRAVA", sport: "Ride", moving: 600, elapsed: nil, readable: true, .hiddenByStrava),
		ActivityRowCase("STRAVA", sport: "Ride", moving: -1, elapsed: 600, readable: true, .hiddenByStrava),
		ActivityRowCase("STRAVA", sport: "Ride", moving: 600, elapsed: -1, readable: true, .hiddenByStrava),
		ActivityRowCase("STRAVA", sport: "Ride", moving: 0, elapsed: 0, readable: true, .activity(ride)),
		ActivityRowCase("STRAVA", sport: "Ride", moving: 600, elapsed: 600, readable: false, .unreadable),
		ActivityRowCase("strava", sport: nil, moving: nil, elapsed: nil, readable: true, .activity(ride)),
		ActivityRowCase("UPLOAD", sport: nil, moving: nil, elapsed: nil, readable: true, .activity(ride)),
		ActivityRowCase(nil, sport: nil, moving: nil, elapsed: nil, readable: true, .activity(ride)),
		ActivityRowCase(nil, sport: "Ride", moving: 600, elapsed: 600, readable: false, .unreadable),
	])
	func rowIsClassifiedByTheStravaRuleThenByWhetherItCouldBeRead(sample: ActivityRowCase) {
		#expect(
			ActivityRow(
				source: sample.source, sport: sample.sport, movingTime: sample.moving,
				elapsedTime: sample.elapsed, activity: sample.readable ? Self.ride : nil)
				== sample.row)
	}

	@Test func countsAddUpToEveryRowTheSourceReturned() throws {
		let range = try ReadRange(oldest: "1998-06-01", newest: "1998-06-13", today: "1998-06-13")
		let listing = ActivityListing(
			range: range,
			rows: [
				.hiddenByStrava, .activity(Self.ride), .unreadable, .hiddenByStrava,
				.activity(.recorded("i1234568", nil, on: "1998-06-09")), .unreadable, .unreadable,
			])
		#expect(listing.activities.map(\.id.rawValue) == ["i1234567", "i1234568"])
		#expect(listing.hiddenByStrava == 2)
		#expect(listing.unreadable == 3)
		#expect(listing.total == 7)
		#expect(listing.range == range)
		let empty = ActivityListing(range: range, rows: [])
		#expect(empty.activities.isEmpty)
		#expect(empty.total == 0)
	}

	@Test func activitiesAreOrderedByStartThenIdentifier() throws {
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
		#expect(listing.activities.map(\.id.rawValue) == ["i9", "i2", "i3", "i4", "i5"])
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

struct ActivityRowCase: Sendable, CustomTestStringConvertible {
	let source: String?
	let sport: String?
	let moving: Double?
	let elapsed: Double?
	let readable: Bool
	let row: ActivityRow

	init(
		_ source: String?, sport: String?, moving: Double?, elapsed: Double?, readable: Bool,
		_ row: ActivityRow
	) {
		self.source = source
		self.sport = sport
		self.moving = moving
		self.elapsed = elapsed
		self.readable = readable
		self.row = row
	}

	var testDescription: String {
		let times = [moving, elapsed].map { $0.map { "\($0)" } ?? "none" }
		return
			"source \(source ?? "none"), sport \(sport ?? "none"), times \(times), readable \(readable)"
	}
}
