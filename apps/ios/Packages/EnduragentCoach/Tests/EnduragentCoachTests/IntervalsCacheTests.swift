import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Test func wellnessDoesNotReplayResponseCookies() async throws {
		let server = try CacheableHTTPServer(
			responseHeaders: { count in
				count == 1 ? ["Set-Cookie: session=test-cookie; Path=/; HttpOnly"] : []
			}
		) { _ in
			"[{\"id\":\"1998-06-13\",\"ctl\":55}]"
		}
		defer { server.stop() }
		let base = try await server.start()
		let client = IntervalsRESTClient(
			credential: .apiKey("test-cookie-key"), baseURL: base)
		let first = try await client.fetchWellness(oldest: "1998-06-13", newest: "1998-06-13")
		let second = try await client.fetchWellness(oldest: "1998-06-13", newest: "1998-06-13")
		let expected = [WellnessDay(date: "1998-06-13", fitness: 55, fatigue: nil, form: nil)]
		#expect(first == expected)
		#expect(second == expected)
		let requests = server.requests.withLock { $0 }
		try #require(requests.count == 2)
		let authorization = Data("API_KEY:test-cookie-key".utf8).base64EncodedString()
		for request in requests {
			#expect(request.contains("Authorization: Basic \(authorization)\r\n"))
			#expect(!request.lowercased().contains("\r\ncookie:"))
		}
	}

	@Test func wellnessIsNotServedFromCache() async throws {
		let server = try CacheableHTTPServer { count in
			"[{\"id\":\"1998-06-13\",\"ctl\":\(count == 1 ? 55 : 56)}]"
		}
		defer { server.stop() }
		let base = try await server.start()
		let client = IntervalsRESTClient(
			credential: .apiKey("test-cache-key"), baseURL: base)
		let first = try await client.fetchWellness(oldest: "1998-06-13", newest: "1998-06-13")
		let second = try await client.fetchWellness(oldest: "1998-06-13", newest: "1998-06-13")
		#expect(first == [WellnessDay(date: "1998-06-13", fitness: 55, fatigue: nil, form: nil)])
		#expect(second == [WellnessDay(date: "1998-06-13", fitness: 56, fatigue: nil, form: nil)])
		let requests = server.requests.withLock { $0 }
		#expect(requests.count == 2)
		let authorization = Data("API_KEY:test-cache-key".utf8).base64EncodedString()
		for request in requests {
			#expect(
				request.hasPrefix(
					"GET /athlete/0/wellness?oldest=1998-06-13&newest=1998-06-13 HTTP/1.1\r\n"))
			#expect(request.contains("Authorization: Basic \(authorization)\r\n"))
		}
	}
}
