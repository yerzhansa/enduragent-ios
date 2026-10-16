import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct IntervalsWriteTests {
		static let saved =
			#"{"id":42,"start_date_local":"1998-06-14T00:00:00","name":"Endurance","category":"WORKOUT","type":"Ride","description":"- 60m 65%","moving_time":3600,"icu_training_load":52,"external_id":"cycling-coach:6F1E2D3C-4B5A-4978-8796-A5B4C3D2E1F0","uid":"server-owned","tags":["cycling-coach"]}"#

		enum Kind: String, CaseIterable, Sendable {
			case create, update, delete
		}

		struct Exchange: Sendable, CustomTestStringConvertible {
			let kind: Kind
			let status: Int
			let body: String
			let answer: IntervalsWriteAnswer

			var testDescription: String { "\(kind) answered \(status) \(body)" }
		}

		static let exchanges: [Exchange] =
			[
				Exchange(kind: .create, status: 200, body: "[\(saved)]", answer: .saved(event)),
				Exchange(kind: .create, status: 200, body: "[]", answer: .lost(.unreadableBody)),
				Exchange(
					kind: .create, status: 200, body: "[\(saved),\(saved)]",
					answer: .lost(.unreadableBody)),
				Exchange(kind: .create, status: 200, body: saved, answer: .lost(.unreadableBody)),
				Exchange(kind: .update, status: 200, body: saved, answer: .saved(event)),
				Exchange(
					kind: .update, status: 200, body: #"{"invalid":true}"#,
					answer: .lost(.unreadableBody)),
				Exchange(
					kind: .update, status: 200, body: "not json", answer: .lost(.unreadableBody)),
				Exchange(kind: .delete, status: 200, body: "", answer: .saved(nil)),
			]
			+ Kind.allCases.flatMap { kind in
				[
					Exchange(kind: kind, status: 404, body: "{}", answer: .httpStatus(404)),
					Exchange(kind: kind, status: 422, body: saved, answer: .httpStatus(422)),
					Exchange(kind: kind, status: 503, body: "", answer: .httpStatus(503)),
				]
			}

		static var event: CalendarEvent {
			CalendarEvent(
				description: "- 60m 65%", type: "Ride", id: EventID(rawValue: 42),
				startDateLocal: "1998-06-14T00:00:00", name: "Endurance", category: "WORKOUT",
				externalId: "cycling-coach:6F1E2D3C-4B5A-4978-8796-A5B4C3D2E1F0",
				uid: "server-owned",
				tags: [IntervalsPolicy.coachTag], coachCreated: true, movingTime: 3600,
				trainingLoad: 52)
		}

		@Test func anAddIsOneBulkUpsertWhoseArrayHoldsTheAddsBody() async throws {
			let requests = answering(200, "[\(Self.saved)]")
			let (payload, identity) = try add()

			let answer = await client().write(.create(payload, identity: identity))

			#expect(answer == .saved(Self.event))
			#expect(requests.methods.count == 1)
			let request = try #require(IntervalsURLProtocolStub.lastRequest)
			let url = try #require(request.url)
			#expect(request.httpMethod == "POST")
			#expect(url.path == "/api/v1/athlete/0/events/bulk")
			#expect(
				URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
					URLQueryItem(name: "upsert", value: "true"),
					URLQueryItem(name: "upsertOnUid", value: "false"),
					URLQueryItem(name: "updatePlanApplied", value: "false"),
				])
			#expect(try sentBody() == .array([payload.requestBody(identity)]))
		}

		@Test func anEditIsOnePutOfThePatchAndADeleteIsOneDelete() async throws {
			let requests = answering(200, Self.saved)
			let patch = WorkoutPatch(
				date: "1998-06-15", name: "Endurance", durationSeconds: 3600, description: nil,
				trainingLoad: 52, workoutDocument: nil)
			let target = EventID(rawValue: 42)

			#expect(await client().write(.update(target, patch)) == .saved(Self.event))
			#expect(IntervalsURLProtocolStub.lastRequest?.httpMethod == "PUT")
			#expect(
				IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/0/events/42")
			#expect(try sentBody() == patch.requestBody)

			#expect(await client().write(.delete(target)) == .saved(nil))
			#expect(IntervalsURLProtocolStub.lastRequest?.httpMethod == "DELETE")
			#expect(
				IntervalsURLProtocolStub.lastRequest?.url?.path == "/api/v1/athlete/0/events/42")
			#expect(requests.methods == ["PUT", "DELETE"])
		}

		@Test(arguments: exchanges)
		func eachAnswerKeepsWhatIntervalsSaidAndIsAskedOnce(exchange: Exchange) async throws {
			let requests = answering(exchange.status, exchange.body)

			let answer = await client().write(try write(exchange.kind))

			#expect(answer == exchange.answer)
			#expect(requests.methods.count == 1)
		}

		@Test(arguments: [Kind.create, .update, .delete], [URLError.Code.timedOut, .cancelled])
		func aWriteWithNoAnswerIsLostAndAskedOnce(kind: Kind, failure: URLError.Code)
			async throws
		{
			let requests = SentWrites()
			IntervalsURLProtocolStub.reset()
			IntervalsURLProtocolStub.handler = { request in
				requests.append(request)
				throw URLError(failure)
			}

			let answer = await client().write(try write(kind))

			#expect(answer == .lost(failure == .cancelled ? .canceled : .transport))
			#expect(requests.methods.count == 1)
		}

		private func answering(_ status: Int, _ body: String) -> SentWrites {
			let requests = SentWrites()
			IntervalsURLProtocolStub.reset()
			IntervalsURLProtocolStub.handler = { request in
				requests.append(request)
				return (status, Data(body.utf8))
			}
			return requests
		}

		private func client() -> IntervalsRESTClient {
			let configuration = URLSessionConfiguration.ephemeral
			configuration.protocolClasses = [IntervalsURLProtocolStub.self]
			return IntervalsRESTClient(
				credential: .apiKey("test-write-key"),
				session: URLSession(configuration: configuration))
		}

		private func add() throws -> (CalendarPayload, CalendarWriteID) {
			(
				try CalendarPayload.ride(
					try JSONValue.parse(
						#"{"date":"1998-06-14","trainingLoad":52,"workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":60,"high":70}}]}}"#
					), today: "1998-06-13"),
				CalendarWriteID(
					rawValue: try #require(UUID(uuidString: "6F1E2D3C-4B5A-4978-8796-A5B4C3D2E1F0"))
				)
			)
		}

		private func write(_ kind: Kind) throws -> CalendarWrite {
			switch kind {
			case .create:
				let (payload, identity) = try add()
				return .create(payload, identity: identity)
			case .update:
				return .update(
					EventID(rawValue: 42),
					WorkoutPatch(
						date: nil, name: "Endurance", durationSeconds: nil, description: nil,
						trainingLoad: nil, workoutDocument: nil))
			case .delete:
				return .delete(EventID(rawValue: 42))
			}
		}

		private func sentBody() throws -> JSONValue {
			let data = try #require(IntervalsURLProtocolStub.lastBody)
			return try JSONValue.parse(String(decoding: data, as: UTF8.self))
		}
	}
}

final class SentWrites: Sendable {
	private let sent = Mutex<[String]>([])

	var methods: [String] { sent.withLock { $0 } }

	func append(_ request: URLRequest) {
		sent.withLock { $0.append(request.httpMethod ?? "") }
	}
}
