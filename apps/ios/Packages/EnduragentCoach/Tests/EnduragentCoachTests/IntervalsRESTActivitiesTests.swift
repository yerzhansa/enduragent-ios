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
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path.hasSuffix("/athlete/0/activities") == true)
		#expect(
			listing.activities.map(\.id.rawValue) == [
				"i1234567", "i1234568", "i1234569", "i1234570", "i1234571", "i1234572",
				"i1234573", "i1234574", "i1234575",
			])
		#expect(listing.hiddenByStrava == 1)
		#expect(listing.unreadable == 1)
		#expect(listing.total == 11)
	}

	@Test func completeActivityRowKeepsEveryMeasurement() async throws {
		let listing = try await week()
		#expect(
			listing.activities.first
				== .recorded(
					"i1234567", "Sunday long ride", on: "1998-06-07", at: 8 * 3_600,
					[
						.duration: 7_200, .distance: 62_400.5, .load: 120, .intensity: 78.5,
						.averagePower: 172, .weightedPower: 196, .averageHeartRate: 141,
						.maxHeartRate: 173, .ftp: 250, .elevationGain: 640.5,
					]))
	}

	@Test func activityRowWithoutDurationAndDistanceHasNeitherReading() async throws {
		let tempo = try #require(try await week().activities.first { $0.id.rawValue == "i1234568" })
		#expect(tempo == .recorded("i1234568", "Tuesday tempo", on: "1998-06-09", at: 27_000, [.load: 80]))
		#expect(tempo.readings[.duration] == nil)
		#expect(tempo.readings[.distance] == nil)
	}

	@Test func twoActivitiesWithTheSameDayAndTitleStayTwoRows() async throws {
		let lunch = try await week().activities.filter { $0.name == "Lunch ride" }
		#expect(lunch.map(\.id.rawValue) == ["i1234569", "i1234570"])
		#expect(lunch.map(\.start.date) == ["1998-06-10", "1998-06-10"])
		#expect(lunch.map(\.start.secondOfDay) == [12 * 3_600 + 15 * 60, 18 * 3_600 + 5])
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
		let spin = try #require(try await week().activities.last)
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

	private func week() async throws -> ActivityListing {
		try await makeClient().activities(
			in: try ReadRange(oldest: "1998-06-06", newest: "1998-06-13", today: "1998-06-13"))
	}
}
