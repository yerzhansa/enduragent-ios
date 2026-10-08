import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite(.serialized)
struct IntervalsRESTClientTests {
	@Test func basicAuthHeaderBytes() async throws {
		let client = try makeClient(credential: .apiKey("test-key"))
		_ = try await client.fetchAthlete()
		let expected = "Basic " + Data("API_KEY:test-key".utf8).base64EncodedString()
		#expect(
			IntervalsURLProtocolStub.lastRequest?.value(forHTTPHeaderField: "Authorization")
				== expected)
		#expect(
			IntervalsURLProtocolStub.lastRequest?.timeoutInterval == IntervalsPolicy.requestTimeout)
	}

	@Test func oauthSendsBearer() async throws {
		let client = try makeClient(
			credential: .oauth(access: "access-token", refresh: "refresh-token"))
		_ = try await client.fetchAthlete()
		#expect(
			IntervalsURLProtocolStub.lastRequest?.value(forHTTPHeaderField: "Authorization")
				== "Bearer access-token"
		)
	}

	@Test func fetchAthleteReadsAda() async throws {
		let client = try makeClient()
		let athlete = try await client.fetchAthlete()
		#expect(athlete.id == "i1001")
		#expect(athlete.name == "Ada Kovač")
		#expect(athlete.ftp == 250)
	}

	@Test func wellnessDecodeMapsCtlAtlAndHidesThemOnWellnessDay() async throws {
		let client = try makeClient()
		let days = try await client.fetchWellness(oldest: "1998-06-12", newest: "1998-06-13")
		#expect(days.count == 2)
		let today = try #require(days.first { $0.date == "1998-06-13" })
		#expect(today.fitness == 55.2)
		#expect(today.fatigue == 42.1)
		#expect(today.form == 55.2 - 42.1)
	}

	@Test(arguments: [#""ramp_rate":"invalid""#, #""fatigue":"invalid""#, #""fatigue":2.5"#])
	func wellnessLoadsWithMalformedUnusedFields(unusedField: String) async throws {
		let client = try makeClient()
		let body = #"[{"id":"1998-06-13","ctl":55.2,"atl":42.1,\#(unusedField)}]"#
		IntervalsURLProtocolStub.handler = { _ in (200, Data(body.utf8)) }
		let days = try await client.fetchWellness(oldest: "1998-06-13", newest: "1998-06-13")
		#expect(
			days == [
				WellnessDay(date: "1998-06-13", fitness: 55.2, fatigue: 42.1, form: 55.2 - 42.1)
			])
	}

	@Test func fetchActivitiesProjectsAdaRides() async throws {
		let client = try makeClient()
		let rows = try await client.fetchActivities(oldest: "1998-06-01", newest: "1998-06-13")
		#expect(rows.map(\.name) == ["Sunday long ride", "Tuesday tempo"])
		#expect(rows[0].date == "1998-06-07")
		#expect(rows[0].durationS == 7200)
		#expect(rows[0].trainingLoad == 120)
	}

	@Test func listEventsDoesNotFilterAwayMovedIdentities() async throws {
		let client = try makeClient()
		let events = try await client.listEvents(oldest: "1998-06-14", newest: "1998-06-20")
		let items =
			URLComponents(
				url: try #require(IntervalsURLProtocolStub.lastRequest?.url),
				resolvingAgainstBaseURL: false
			)?.queryItems ?? []
		let categories = items.filter { $0.name == "category" }.compactMap(\.value)
		#expect(categories.isEmpty)
		#expect(events[0].coachCreated)
		#expect(events[0].name == "Endurance")
		#expect(!events[1].coachCreated)
	}

	@Test func fetchStreamsReturnsSummaryWithoutSeries() async throws {
		let client = try makeClient()
		let summary = try await client.fetchStreams(
			id: try #require(ActivityID(rawValue: "i1234567")))
		let expected = try JSONValue.parse(
			try #require(String(data: try fixtureData("streams-ts"), encoding: .utf8)))
		#expect(summary.canonicalDigestInput() == expected.canonicalDigestInput())
		let encoded = canonicalJSON(summary)
		#expect(!encoded.contains("\"data\""))
	}

	@Test func rangeOf367DaysIsRejected() async throws {
		let client = try makeClient()
		let oldest: CivilDate = "1998-01-01"
		let newest = oldest.adding(days: 366)
		do {
			_ = try await client.fetchActivities(oldest: oldest, newest: newest)
			Issue.record("expected range_too_wide")
		} catch let error as IntervalsError {
			#expect(error.code == "range_too_wide")
		}
		do {
			_ = try await client.listEvents(oldest: oldest, newest: newest)
			Issue.record("expected range_too_wide")
		} catch let error as IntervalsError {
			#expect(error.code == "range_too_wide")
		}
		#expect(IntervalsURLProtocolStub.lastRequest == nil)
	}

	@Test func inclusive366DaysIsAllowed() async throws {
		let client = try makeClient()
		let oldest: CivilDate = "1998-01-01"
		let newest = oldest.adding(days: 365)
		_ = try await client.fetchActivities(oldest: oldest, newest: newest)
		#expect(IntervalsURLProtocolStub.lastRequest != nil)
	}

	@Test func createChatEventPostsSnakeCaseBodyWithoutForbiddenFields() async throws {
		let client = try makeClient(
			clock: FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		)
		var draft = try CyclingTools.parseCreateWorkoutInput(
			try JSONValue.parse(
				#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}}]}}"#
			),
			today: "1998-06-13"
		).draft
		draft.writeID = CalendarWriteID()
		let event = try await client.createChatEvent(draft)
		let request = try #require(IntervalsURLProtocolStub.lastRequest)
		#expect(request.httpMethod == "POST")
		#expect(request.url?.path.hasSuffix("/athlete/0/events") == true)
		#expect(request.url?.query == "upsertOnUid=true")
		let data = try #require(IntervalsURLProtocolStub.lastBody)
		let body = try #require(String(data: data, encoding: .utf8))
		#expect(body.contains("\"start_date_local\""))
		#expect(body.contains("\"external_id\""))
		#expect(!body.contains("moving_time"))
		#expect(!body.contains("icu_training_load"))
		#expect(body.contains("\"uid\""))
		#expect(!body.contains("workout_doc"))
		#expect(event.name == "Endurance")
	}

	@Test func deleteRefusesRaceCategory() async throws {
		let client = try makeClient(
			clock: FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		)
		do {
			try await client.deleteEvent(id: EventID(rawValue: 43))
			Issue.record("expected not_a_workout")
		} catch let error as IntervalsError {
			#expect(error.code == "not_a_workout")
		}
	}

	@Test func selectedAthleteGoesIntoEveryAthletePath() async throws {
		let coached = try #require(IntervalsAthleteID(rawValue: "i2002"))
		let client = try makeClient(athlete: .athlete(coached))
		_ = try await client.fetchAthlete()
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002")
		_ = try await client.fetchWellness(oldest: "1998-06-12", newest: "1998-06-13")
		#expect(
			IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002/wellness")
		_ = try await client.listEvents(oldest: "1998-06-12", newest: "1998-06-13")
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002/events")
		let owner = try makeClient(athlete: .keyOwner)
		_ = try await owner.fetchAthlete()
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/0")
	}

	@Test func vaultReadsTheSelectedAthleteThroughREST() async throws {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		let vault = testVault(secrets, training: .rest(session: try stubSession()))
		let coached = try #require(IntervalsAthleteID(rawValue: "i2002"))
		let outcome = await vault.change(.replace(apiKey: "test-key", athlete: .athlete(coached))) {
			false
		}
		guard case .replaced(let summary, _) = outcome else {
			Issue.record("Expected a saved connection")
			return
		}
		#expect(summary.wellness == .waiting)
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002")
		let displayed = Mutex<TrainingStatus?>(nil)
		await vault.refreshTrainingDisplay(
			from: summary, isCurrent: { true },
			publish: { status in
				displayed.withLock { $0 = status }
			})
		guard case .connected(let refreshed, _) = displayed.withLock({ $0 }) else {
			Issue.record("Expected the refreshed saved connection")
			return
		}
		#expect(refreshed.wellness != .waiting)
		#expect(
			IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002/wellness")
		#expect(try secrets.intervalsConnection()?.selection == .athlete(coached))
		_ = try await vault.trainingConnection().client.fetchAthlete()
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002")
	}

	private func makeClient(
		credential: IntervalsCredential = .apiKey("test-key"),
		athlete: AthleteSelection = .keyOwner,
		clock: any Clock = SystemClock()
	) throws -> IntervalsRESTClient {
		IntervalsRESTClient(
			credential: credential, athlete: athlete, session: try stubSession(), clock: clock)
	}

	private func stubSession() throws -> URLSession {
		IntervalsURLProtocolStub.reset()
		IntervalsURLProtocolStub.handler = { request in
			let path = request.url?.path ?? ""
			let method = request.httpMethod ?? "GET"
			if path.hasSuffix("/streams.json") {
				return (200, try fixtureData("intervals-streams"))
			}
			if path.contains("/wellness") {
				return (200, try fixtureData("intervals-wellness"))
			}
			if path.contains("/activities") {
				return (200, try fixtureData("intervals-activities"))
			}
			if path.contains("/events/") {
				if path.hasSuffix("/43") {
					let race = """
						{"id":43,"start_date_local":"1998-06-20T00:00:00","name":"Local race","category":"RACE_A","tags":[]}
						"""
					return (200, Data(race.utf8))
				}
				let owned = """
					{"id":42,"start_date_local":"1998-06-14T00:00:00","name":"Endurance","category":"WORKOUT","external_id":"cycling-coach:1998-06-14:endurance","tags":["cycling-coach"]}
					"""
				return (200, Data(owned.utf8))
			}
			if path.contains("/events") {
				if method == "POST" {
					let data = try #require(IntervalsURLProtocolStub.lastBody)
					var fields = try JSONValue.parse(String(decoding: data, as: UTF8.self))
						.objectFields
					fields["id"] = .number(1)
					return (200, Data(JSONValue.object(fields).canonicalDigestInput().utf8))
				}
				return (200, try fixtureData("intervals-events"))
			}
			if path.contains("/activity/") {
				return (200, try fixtureData("intervals-activity"))
			}
			return (200, try fixtureData("intervals-athlete"))
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [IntervalsURLProtocolStub.self]
		configuration.timeoutIntervalForRequest = IntervalsPolicy.requestTimeout
		return URLSession(configuration: configuration)
	}
}

final class IntervalsURLProtocolStub: URLProtocol, @unchecked Sendable {
	nonisolated(unsafe) static var lastRequest: URLRequest?
	nonisolated(unsafe) static var lastBody: Data?
	nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
	private static let lock = NSLock()

	static func reset() {
		lock.lock()
		lastRequest = nil
		lastBody = nil
		handler = nil
		lock.unlock()
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		Self.lock.lock()
		Self.lastRequest = request
		Self.lastBody = Self.copyBody(request)
		let handler = Self.handler
		Self.lock.unlock()
		do {
			let (status, body) = try handler?(request) ?? (500, Data())
			let url = try #require(request.url)
			let response = try #require(
				HTTPURLResponse(
					url: url,
					statusCode: status,
					httpVersion: "HTTP/1.1",
					headerFields: ["Content-Type": "application/json"]
				)
			)
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: body)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override func stopLoading() {}

	private static func copyBody(_ request: URLRequest) -> Data? {
		if let body = request.httpBody {
			return body
		}
		guard let stream = request.httpBodyStream else {
			return nil
		}
		stream.open()
		defer { stream.close() }
		var data = Data()
		let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
		defer { buffer.deallocate() }
		while stream.hasBytesAvailable {
			let count = stream.read(buffer, maxLength: 4096)
			if count > 0 {
				data.append(buffer, count: count)
			} else {
				break
			}
		}
		return data
	}
}

func fixtureData(_ name: String) throws -> Data {
	guard
		let url = Bundle.module.url(
			forResource: name, withExtension: "json", subdirectory: "Fixtures")
	else {
		throw URLError(.fileDoesNotExist)
	}
	return try Data(contentsOf: url)
}
