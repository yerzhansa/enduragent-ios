import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Test func activitiesAreAskedForTheRangeAndCountedByKind() async throws {
		let listing = try await week()
		#expect(
			IntervalsURLProtocolStub.lastRequest?.url?.query
				== "oldest=1998-06-06&newest=1998-06-13")
		#expect(
			IntervalsURLProtocolStub.lastRequest?.url?.path.hasSuffix("/athlete/0/activities")
				== true)
		#expect(
			listing.activities.map(\.id.rawValue) == [
				"i1234575", "i1234574", "i1234573", "i1234572", "i1234571", "i1234570",
				"i1234569", "i1234568", "i1234567",
			])
		#expect(listing.hiddenByStrava == 1)
		#expect(listing.unreadable == 1)
		#expect(listing.total == 11)
	}

	@Test func completeActivityRowKeepsEveryMeasurement() async throws {
		let listing = try await week()
		#expect(
			listing.activities.last
				== .recorded(
					"i1234567", "Sunday long ride", on: "1998-06-07", at: 8 * 3_600, ftp: 250,
					[
						.duration: 7_200, .distance: 62_400.5, .load: 120, .intensity: 78.5,
						.averagePower: 172, .weightedPower: 196, .averageHeartRate: 141,
						.maxHeartRate: 173, .elevationGain: 640.5,
					]))
	}

	@Test func activityRowWithoutDurationAndDistanceHasNeitherReading() async throws {
		let tempo = try #require(try await week().activities.first { $0.id.rawValue == "i1234568" })
		#expect(
			tempo
				== .recorded("i1234568", "Tuesday tempo", on: "1998-06-09", at: 27_000, [.load: 80])
		)
		#expect(tempo.readings[.duration] == nil)
		#expect(tempo.readings[.distance] == nil)
	}

	@Test func twoActivitiesWithTheSameDayAndTitleStayTwoRows() async throws {
		let lunch = try await week().activities.filter { $0.name == "Lunch ride" }
		#expect(lunch.map(\.id.rawValue) == ["i1234570", "i1234569"])
		#expect(lunch.map(\.start.date) == ["1998-06-10", "1998-06-10"])
		#expect(lunch.map(\.start.secondOfDay) == [18 * 3_600 + 5, 12 * 3_600 + 15 * 60])
	}

	@Test(arguments: [("i1234571", "i1234572", 29), ("i1234573", "i1234574", 31)])
	func startsKeepTheMinutesBetweenTwoActivities(first: String, second: String, minutes: Int)
		async throws
	{
		let listing = try await week()
		let earlier = try #require(listing.activities.first { $0.id.rawValue == first })
		let later = try #require(listing.activities.first { $0.id.rawValue == second })
		#expect(earlier.start.date == later.start.date)
		let from = try #require(earlier.start.secondOfDay)
		let until = try #require(later.start.secondOfDay)
		#expect(until - from == minutes * 60)
	}

	@Test func startWithoutATimeOfDayIsTheDateAlone() async throws {
		let spin = try #require(try await week().activities.first)
		#expect(spin.id.rawValue == "i1234575")
		#expect(spin.start == LocalStart(date: "1998-06-13", secondOfDay: nil))
	}

	@Test func activitiesResponseThatIsNotAListThrows() async throws {
		let client = try makeClient()
		IntervalsURLProtocolStub.handler = { _ in (200, Data(#"{"activities":[]}"#.utf8)) }
		await #expect(
			throws: IntervalsError(
				code: "invalid_json", details: "activities response was not an array")
		) {
			_ = try await client.activities(in: .day("1998-06-13"))
		}
	}

	@Test(arguments: [
		ActivityRowCase(
			"STRAVA", sport: nil, moving: nil, elapsed: nil, readable: true, .hiddenByStrava),
		ActivityRowCase(
			"STRAVA", sport: nil, moving: nil, elapsed: nil, readable: false, .hiddenByStrava),
		ActivityRowCase(
			"STRAVA", sport: nil, moving: 600, elapsed: 600, readable: true, .hiddenByStrava),
		ActivityRowCase(
			"STRAVA", sport: "Ride", moving: nil, elapsed: 600, readable: true, .hiddenByStrava),
		ActivityRowCase(
			"STRAVA", sport: "Ride", moving: 600, elapsed: nil, readable: true, .hiddenByStrava),
		ActivityRowCase(
			"STRAVA", sport: "Ride", moving: -1, elapsed: 600, readable: true, .hiddenByStrava),
		ActivityRowCase(
			"STRAVA", sport: "Ride", moving: 600, elapsed: -1, readable: true, .hiddenByStrava),
		ActivityRowCase(
			"STRAVA", sport: "Ride", moving: 0, elapsed: 0, readable: true, .listed),
		ActivityRowCase(
			"STRAVA", sport: "Ride", moving: 600, elapsed: 600, readable: false, .unreadable),
		ActivityRowCase(
			"strava", sport: nil, moving: nil, elapsed: nil, readable: true, .listed),
		ActivityRowCase(
			"UPLOAD", sport: nil, moving: nil, elapsed: nil, readable: true, .listed),
		ActivityRowCase(nil, sport: nil, moving: nil, elapsed: nil, readable: true, .listed),
		ActivityRowCase(
			nil, sport: "Ride", moving: 600, elapsed: 600, readable: false, .unreadable),
	])
	func rowIsClassifiedByTheStravaRuleThenByWhetherItCouldBeRead(sample: ActivityRowCase)
		async throws
	{
		let client = try makeClient()
		let body = Data(canonicalJSON(.array([sample.wire])).utf8)
		IntervalsURLProtocolStub.handler = { _ in (200, body) }
		let listing = try await client.activities(in: .day("1998-06-07"))
		#expect(
			[listing.activities.count, listing.hiddenByStrava, listing.unreadable]
				== sample.kind.counts)
	}

	private func week() async throws -> ActivityListing {
		try await makeClient().activities(
			in: try ReadRange(oldest: "1998-06-06", newest: "1998-06-13", today: "1998-06-13"))
	}
}

struct ActivityRowCase: Sendable, CustomTestStringConvertible {
	enum Kind: Sendable {
		case listed
		case hiddenByStrava
		case unreadable

		var counts: [Int] {
			switch self {
			case .listed: [1, 0, 0]
			case .hiddenByStrava: [0, 1, 0]
			case .unreadable: [0, 0, 1]
			}
		}
	}

	let source: String?
	let sport: String?
	let moving: Double?
	let elapsed: Double?
	let readable: Bool
	let kind: Kind

	init(
		_ source: String?, sport: String?, moving: Double?, elapsed: Double?, readable: Bool,
		_ kind: Kind
	) {
		self.source = source
		self.sport = sport
		self.moving = moving
		self.elapsed = elapsed
		self.readable = readable
		self.kind = kind
	}

	var wire: JSONValue {
		var fields: [String: JSONValue] = ["id": .string("i1234567")]
		if readable { fields["start_date_local"] = .string("1998-06-07T08:00:00") }
		if let source { fields["source"] = .string(source) }
		if let sport { fields["type"] = .string(sport) }
		if let moving { fields["moving_time"] = .number(moving) }
		if let elapsed { fields["elapsed_time"] = .number(elapsed) }
		return .object(fields)
	}

	var testDescription: String {
		let times = [moving, elapsed].map { $0.map { "\($0)" } ?? "none" }
		return
			"source \(source ?? "none"), sport \(sport ?? "none"), times \(times), readable \(readable)"
	}
}
