import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class OpenRouterStub: URLProtocol, @unchecked Sendable {
	struct Reply: Sendable {
		var status: Int
		var headers: [String: String]
		var body: Data

		static func sse(_ text: String) -> Reply {
			Reply(
				status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(text.utf8))
		}

		static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Reply {
			Reply(
				status: status,
				headers: headers.merging(["Content-Type": "application/json"]) { own, _ in own },
				body: Data(body.utf8)
			)
		}
	}

	enum Outcome: Sendable {
		case reply(Reply)
		case fail(URLError.Code)
	}

	private static let routes = Mutex<[String: @Sendable (URLRequest) -> Outcome]>([:])

	static func transport(
		diagnostics: DiagnosticsLog = DiagnosticsLog(clock: SystemClock()),
		onSession: @escaping @Sendable (TimeInterval) -> Void = { _ in },
		handler: @escaping @Sendable (URLRequest) -> Outcome
	) throws -> OpenRouterTransport {
		let host = "\(UUID().uuidString.lowercased()).openrouter.test"
		routes.withLock { $0[host] = handler }
		return OpenRouterTransport(
			baseURL: try #require(URL(string: "https://\(host)/api/v1")),
			diagnostics: diagnostics
		) { timeout in
			onSession(timeout)
			let configuration = URLSessionConfiguration.ephemeral
			configuration.timeoutIntervalForRequest = timeout
			configuration.protocolClasses = [OpenRouterStub.self]
			return URLSession(configuration: configuration)
		}
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url, let host = url.host(),
			let handler = Self.routes.withLock({ $0[host] })
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
			return
		}
		switch handler(request) {
		case .fail(let code):
			client?.urlProtocol(self, didFailWithError: URLError(code))
		case .reply(let reply):
			guard
				let http = HTTPURLResponse(
					url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
					headerFields: reply.headers)
			else {
				client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
				return
			}
			client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: reply.body)
			client?.urlProtocolDidFinishLoading(self)
		}
	}

	override func stopLoading() {}
}

func collect(_ stream: AsyncThrowingStream<TransportEvent, Error>) async throws
	-> [TransportEvent]
{
	var events: [TransportEvent] = []
	for try await event in stream {
		events.append(event)
	}
	return events
}

func fixture(_ name: String, ext: String) throws -> String {
	let url = try #require(
		Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
			?? Bundle.module.url(forResource: name, withExtension: ext)
	)
	return try String(contentsOf: url, encoding: .utf8)
}

func textDeltas(in events: [TransportEvent]) -> [String] {
	events.compactMap { event in
		if case .textDelta(let text) = event {
			return text
		}
		return nil
	}
}
