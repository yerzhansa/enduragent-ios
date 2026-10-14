import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.serialized)
struct LiveSeedAccountTests {
	static let ride = SeedActivity(
		key: "account-ride", title: "Endurance", sport: .ride,
		start: SeedStart("2026-10-01", 7, 0), blocks: [SeedBlock(minutes: 30, 0.65)])

	static func account(answering handler: @escaping IntervalsURLProtocolStub.Handler)
		-> IntervalsSeedAccount
	{
		SeedAccountURLProtocolStub.reset()
		SeedAccountURLProtocolStub.handler = handler
		return IntervalsSeedAccount(
			client: IntervalsRESTClient(
				credential: .apiKey("icu-test-key"),
				session: ephemeralSession(
					requestTimeout: IntervalsPolicy.requestTimeout,
					protocolClasses: [SeedAccountURLProtocolStub.self])))
	}

	@Test func uploadPostsTheFileAsMultipartWithTheLongWriteTimeout() async throws {
		let account = Self.account { _ in (200, Data(#"{"activities":[{"id":"i9001"}]}"#.utf8)) }
		let file = Data("<TrainingCenterDatabase/>".utf8)

		let id = try await account.upload(Self.ride, file: file)

		let request = try #require(SeedAccountURLProtocolStub.lastRequest)
		let body = try #require(SeedAccountURLProtocolStub.lastBody)
		let type = try #require(request.value(forHTTPHeaderField: "Content-Type"))
		let boundary = try #require(type.split(separator: "boundary=").last.map(String.init))
		#expect(id == "i9001")
		#expect(request.httpMethod == "POST")
		#expect(request.url?.path == "/api/v1/athlete/0/activities")
		#expect(type == "multipart/form-data; boundary=\(boundary)")
		#expect(body.starts(with: Data("--\(boundary)\r\n".utf8)))
		#expect(body.range(of: file) != nil)
		#expect(body.suffix(boundary.utf8.count + 8) == Data("\r\n--\(boundary)--\r\n".utf8))
		#expect(request.timeoutInterval == 120)
	}

	@Test func aClearedWellnessFieldIsSentAsMinusOneBecauseIntervalsIgnoresNull() async throws {
		let account = Self.account { _ in (200, Data("[]".utf8)) }

		try await account.writeWellness(["2026-10-01": ["hrv": nil, "weight": 72.5]])

		let request = try #require(SeedAccountURLProtocolStub.lastRequest)
		let body = try #require(SeedAccountURLProtocolStub.lastBody)
		let rows = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
		let row = try #require(rows.first)
		#expect(request.httpMethod == "PUT")
		#expect(request.url?.path == "/api/v1/athlete/0/wellness-bulk")
		#expect(rows.count == 1)
		#expect(row["id"] as? String == "2026-10-01")
		#expect(row["hrv"] as? Double == -1)
		#expect(row["weight"] as? Double == 72.5)
	}

	@Test func deleteTreatsAnActivityTheAccountNoLongerHasAsDone() async throws {
		let account = Self.account { _ in (404, Data()) }

		try await account.delete("i9001")

		let request = try #require(SeedAccountURLProtocolStub.lastRequest)
		#expect(request.httpMethod == "DELETE")
		#expect(request.url?.path == "/api/v1/activity/i9001")
		#expect(request.timeoutInterval == 120)
	}

	@Test func deleteStopsOnAServerError() async throws {
		let account = Self.account { _ in (500, Data("down".utf8)) }

		await #expect(throws: LiveCheckStop.self) { try await account.delete("i9001") }
	}

	@Test func aMissingActivityStopsEveryWriteOtherThanDelete() async throws {
		let account = Self.account { _ in (404, Data()) }

		await #expect(throws: LiveCheckStop.self) {
			try await account.rate("i9001", feel: 2, rpe: 4)
		}
	}
}
