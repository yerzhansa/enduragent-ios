import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Test func detailIsAskedForByItsIdentifierWithLaps() async throws {
		_ = try await makeClient().activity(try id("i1234567"))
		let url = try #require(IntervalsURLProtocolStub.lastRequest?.url)
		#expect(url.path == "/api/v1/activity/i1234567")
		#expect(url.query == "intervals=true")
		#expect(IntervalsURLProtocolStub.lastRequest?.httpMethod == "GET")
	}

	@Test func detailKeepsTheRowAndEveryDetailOnlyField() async throws {
		let asked = try id("i1234567")
		let read = try await makeClient().activity(asked)
		let row = Activity.recorded(
			"i1234567", "Sunday long ride", on: "1998-06-07", at: 8 * 3_600,
			[
				.duration: 7_200, .distance: 62_400.5, .load: 120, .intensity: 78.5,
				.averagePower: 172, .weightedPower: 196, .averageHeartRate: 141,
				.maxHeartRate: 173, .ftp: 250, .elevationGain: 640.5,
			])
		let extras = ActivityDetailExtras(
			notes: "Legs felt heavy on the last climb.", indoor: false,
			readings: Readings([
				.perceivedExertion: 6, .feel: 2, .averageCadence: 86.5, .averageSpeed: 8.667,
				.maxSpeed: 17.2, .calories: 1_480, .work: 1_238_400, .variabilityIndex: 1.14,
				.efficiencyFactor: 1.39, .decoupling: 3.2,
			]),
			powerZoneSeconds: [
				ZoneSeconds(zone: "Z1", seconds: 1_200), ZoneSeconds(zone: "Z2", seconds: 3_600),
				ZoneSeconds(zone: "Z3", seconds: 1_500), ZoneSeconds(zone: "Z4", seconds: 600),
				ZoneSeconds(zone: "Z5", seconds: 240), ZoneSeconds(zone: "SS", seconds: 60),
			],
			heartRateZoneSeconds: [900, 3_900, 1_800, 500, 100])
		#expect(
			read
				== .found(
					try ActivityDetail(
						asked: asked, activity: row, extras: extras, laps: .notSupplied)))
	}

	@Test func detailKeepsEachLapInSourceOrder() async throws {
		let client = try makeClient()
		let body = try fixtureData("intervals-activity-laps")
		IntervalsURLProtocolStub.handler = { _ in (200, body) }
		guard case .found(let detail) = try await client.activity(try id("i1234568")) else {
			Issue.record("expected the activity")
			return
		}
		#expect(detail.extras == ActivityDetailExtras(indoor: true))
		#expect(
			detail.laps
				== .recorded([
					ActivityLap(
						number: 1, label: "Warm-up", kind: "RECOVERY",
						readings: Readings([
							.duration: 600, .distance: 4_800, .load: 6, .intensity: 55,
							.averagePower: 138, .weightedPower: 140, .averageHeartRate: 112,
							.maxHeartRate: 124, .elevationGain: 12.5,
						])),
					ActivityLap(
						number: 2, label: "Sweet spot", kind: "WORK",
						readings: Readings([
							.duration: 1_200, .distance: 11_400, .load: 30, .intensity: 90,
							.averagePower: 224, .weightedPower: 226, .averageHeartRate: 156,
							.maxHeartRate: 164, .elevationGain: 0,
						])),
					ActivityLap(
						number: 3, label: nil, kind: "RECOVERY",
						readings: Readings([.duration: 300])),
				]))
	}

	@Test(arguments: [
		(#"{"id":"i1234569","start_date_local":"1998-06-10T12:15:00","icu_intervals":[]}"#, true),
		(
			#"{"id":"i1234569","start_date_local":"1998-06-10T12:15:00","icu_intervals":null}"#,
			false
		),
		(#"{"id":"i1234569","start_date_local":"1998-06-10T12:15:00"}"#, false),
	])
	func lapsTheSourceDidNotSupplyAreNotAnEmptyLapList(body: String, supplied: Bool)
		async throws
	{
		let client = try makeClient()
		IntervalsURLProtocolStub.handler = { _ in (200, Data(body.utf8)) }
		guard case .found(let detail) = try await client.activity(try id("i1234569")) else {
			Issue.record("expected the activity")
			return
		}
		#expect(detail.laps == (supplied ? .recorded([]) : .notSupplied))
	}

	@Test func answerForAnotherIdentifierIsRefusedAsAMismatch() async throws {
		let client = try makeClient()
		await #expect {
			_ = try await client.activity(try id("i7654321"))
		} throws: {
			($0 as? IntervalsError)?.code == "activity_mismatch"
		}
	}

	@Test func missingActivityIsNotFoundAndAnotherRefusalIsThrown() async throws {
		let client = try makeClient()
		IntervalsURLProtocolStub.handler = { _ in (404, Data(#"{"status":404}"#.utf8)) }
		#expect(try await client.activity(try id("i1234567")) == .notFound)
		IntervalsURLProtocolStub.handler = { _ in (503, Data()) }
		await #expect(throws: IntervalsError(code: "http", details: "status 503", status: 503)) {
			_ = try await client.activity(try id("i1234567"))
		}
	}

	@Test(arguments: [
		(
			#"{"id":"17654331","start_date_local":"1998-06-09T09:00:00","source":"STRAVA","_note":"hidden"}"#,
			true
		),
		(
			#"{"id":"17654331","start_date_local":"1998-06-09T09:00:00","source":"STRAVA","type":"Ride","moving_time":600}"#,
			true
		),
		(
			#"{"id":"17654331","start_date_local":"1998-06-09T09:00:00","source":"STRAVA","type":"Ride","moving_time":600,"elapsed_time":600}"#,
			false
		),
		(#"{"id":"17654331","start_date_local":"1998-06-09T09:00:00","source":"UPLOAD"}"#, false),
	])
	func singleActivityIsHiddenByTheRuleOfTheList(body: String, hidden: Bool) async throws {
		let client = try makeClient()
		IntervalsURLProtocolStub.handler = { _ in (200, Data(body.utf8)) }
		let read = try await client.activity(try id("17654331"))
		#expect((read == .hiddenByStrava) == hidden)
		if case .found(let detail) = read {
			#expect(detail.activity.id.rawValue == "17654331")
		} else {
			#expect(hidden)
		}
	}

	private func id(_ raw: String) throws -> ActivityID {
		try #require(ActivityID(rawValue: raw))
	}
}
