import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite(.serialized)
struct IntervalsRESTClientTests {
	@Test func basicAuthHeaderBytes() async throws {
		let client = try makeClient(credential: .apiKey("test-key"))
		_ = try await client.profile()
		let expected = "Basic " + Data("API_KEY:test-key".utf8).base64EncodedString()
		#expect(
			IntervalsURLProtocolStub.lastRequest?.value(forHTTPHeaderField: "Authorization")
				== expected)
		#expect(
			IntervalsURLProtocolStub.lastRequest?.timeoutInterval == IntervalsPolicy.requestTimeout)
	}

	@Test func exchangeSendsTheCallersBodyTypeAndTimeout() async throws {
		let client = try makeClient()
		let bytes = Data(
			"--edge\r\nContent-Type: application/vnd.garmin.tcx+xml\r\n\r\n<TrainingCenterDatabase/>\r\n--edge--\r\n"
				.utf8)
		let answer = try await client.exchange(
			method: "POST", path: ["athlete", "0", "activities"],
			body: IntervalsBody(data: bytes, contentType: "multipart/form-data; boundary=edge"),
			timeout: 120)
		let request = try #require(IntervalsURLProtocolStub.lastRequest)
		#expect(answer.status == 200)
		#expect(
			request.value(forHTTPHeaderField: "Content-Type")
				== "multipart/form-data; boundary=edge")
		#expect(IntervalsURLProtocolStub.lastBody == bytes)
		#expect(request.timeoutInterval == 120)
	}

	@Test func oauthSendsBearer() async throws {
		let client = try makeClient(
			credential: .oauth(access: "access-token", refresh: "refresh-token"))
		_ = try await client.profile()
		#expect(
			IntervalsURLProtocolStub.lastRequest?.value(forHTTPHeaderField: "Authorization")
				== "Bearer access-token"
		)
	}

	@Test func listEventsDoesNotFilterAwayMovedIdentities() async throws {
		let client = try makeClient()
		let events = try await client.listEvents(
			in: ReadRange(oldest: "1998-06-14", newest: "1998-06-20", today: "1998-06-13"))
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

	@Test func listEventsDecodesDurationLoadAndDocumentAndReadsAnUnnamedEntry() async throws {
		let client = try makeClient()
		let body = """
			[
			{"id":1,"start_date_local":"1998-06-14T00:00:00","name":"Endurance","category":"WORKOUT","moving_time":3600,"icu_training_load":52,"workout_doc":{"steps":[{"duration":3600}]}},
			{"id":2,"start_date_local":"1998-06-15T00:00:00","name":"Opener","category":"WORKOUT","moving_time":0,"icu_training_load":0,"workout_doc":null},
			{"id":3,"start_date_local":"1998-06-16T00:00:00","name":"Spin","category":"WORKOUT","moving_time":null,"icu_training_load":null},
			{"id":4,"start_date_local":"1998-06-17T00:00:00","category":"RACE_A"}
			]
			"""
		IntervalsURLProtocolStub.handler = { _ in (200, Data(body.utf8)) }
		let events = try await client.listEvents(
			in: ReadRange(oldest: "1998-06-14", newest: "1998-06-20", today: "1998-06-13"))
		#expect(events.map(\.movingTime) == [3600, 0, nil, nil])
		#expect(events.map(\.trainingLoad) == [52, 0, nil, nil])
		#expect(
			events.map(\.workoutDocument)
				== [try JSONValue.parse(#"{"steps":[{"duration":3600}]}"#), nil, nil, nil])
		#expect(events.map(\.name) == ["Endurance", "Opener", "Spin", nil])
		#expect(events[3].category == "RACE_A")
	}

	@Test func listEventsAsksForTheRangeFromItsOldestToItsNewestDay() async throws {
		_ = try await makeClient().listEvents(
			in: ReadRange(oldest: "1998-06-14", newest: "1998-06-20", today: "1998-06-13"))

		let request = try #require(IntervalsURLProtocolStub.lastRequest?.url)
		let items =
			URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
		#expect(request.path == "/api/v1/athlete/0/events")
		#expect(items.filter { $0.name == "oldest" }.map(\.value) == ["1998-06-14"])
		#expect(items.filter { $0.name == "newest" }.map(\.value) == ["1998-06-20"])
	}

	enum IneligibleTarget: Sendable {
		case race, athleteOwned, past, movedIntoThePast

		var event: CalendarEvent {
			let owned = self == .past || self == .movedIntoThePast
			return CalendarEvent(
				id: EventID(rawValue: 43),
				startDateLocal: self == .past ? "1998-06-12T00:00:00" : "1998-06-20T00:00:00",
				name: "Endurance", category: self == .race ? "RACE_A" : "WORKOUT",
				externalId: nil, uid: nil, tags: owned ? [IntervalsPolicy.coachTag] : [],
				coachCreated: owned)
		}

		var code: String {
			switch self {
			case .race: "not_a_workout"
			case .athleteOwned: "not_coach_created"
			case .past: "past_workout_protected"
			case .movedIntoThePast: "past_workout_destination"
			}
		}
	}

	@Test(arguments: [
		(IneligibleTarget.race, false), (.race, true), (.athleteOwned, false),
		(.athleteOwned, true), (.past, false), (.past, true), (.movedIntoThePast, false),
	])
	func theOldPathRefusesAnIneligibleTargetWithTodaysCodeBeforeItWrites(
		target: IneligibleTarget, deleting: Bool
	) async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		client.events = [target.event]
		let id = target.event.id
		let input: GatedToolInput =
			deleting
			? .deleteWorkout(eventId: id)
			: .updateWorkout(
				UpdateWorkoutInput(
					eventId: id, date: target == .movedIntoThePast ? "1998-06-12" : nil,
					name: "Endurance", description: nil))
		do {
			_ = try await CalendarWriteOperation.prepare(
				try oldPathProposal(input, writeID: nil), client: client, today: "1998-06-13")
			Issue.record("expected \(target.code)")
		} catch let error as IntervalsError {
			#expect(error.code == target.code)
		}
		#expect(client.calls.allSatisfy { !$0.isWrite })
	}

	@Test func selectedAthleteGoesIntoEveryAthletePath() async throws {
		let coached = try #require(IntervalsAthleteID(rawValue: "i2002"))
		let client = try makeClient(athlete: .athlete(coached))
		_ = try await client.profile()
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002")
		_ = try await client.wellness(
			in: try ReadRange(oldest: "1998-06-12", newest: "1998-06-13", today: "1998-06-13"))
		#expect(
			IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002/wellness")
		_ = try await client.listEvents(
			in: try ReadRange(oldest: "1998-06-12", newest: "1998-06-13", today: "1998-06-13"))
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002/events")
		let owner = try makeClient(athlete: .keyOwner)
		_ = try await owner.profile()
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
		guard case .connected(let training) = try await vault.trainingConnection() else {
			Issue.record("Expected the saved connection to reach coaching")
			return
		}
		_ = try await training.client.profile()
		#expect(IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/i2002")
	}

	func makeClient(
		credential: IntervalsCredential = .apiKey("test-key"),
		athlete: AthleteSelection = .keyOwner
	) throws -> IntervalsRESTClient {
		IntervalsRESTClient(credential: credential, athlete: athlete, session: try stubSession())
	}

	func stubSession() throws -> URLSession {
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
			if method == "POST", path.hasSuffix("/events/bulk") {
				let data = try #require(IntervalsURLProtocolStub.lastBody)
				let sent =
					try JSONValue.parse(String(decoding: data, as: UTF8.self)).arrayValue ?? []
				let saved = sent.enumerated().map { index, event in
					var fields = event.objectFields
					fields["id"] = .number(Double(index + 1))
					return JSONValue.object(fields)
				}
				return (200, Data(JSONValue.array(saved).canonicalDigestInput().utf8))
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

func fixtureData(_ name: String) throws -> Data {
	guard
		let url = Bundle.module.url(
			forResource: name, withExtension: "json", subdirectory: "Fixtures")
	else {
		throw URLError(.fileDoesNotExist)
	}
	return try Data(contentsOf: url)
}
