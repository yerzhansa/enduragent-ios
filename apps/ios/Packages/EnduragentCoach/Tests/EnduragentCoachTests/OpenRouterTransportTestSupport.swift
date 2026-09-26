import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

func sampleRequest(tools: Bool) -> CompletionRequest {
	CompletionRequest.openRouter(
		messages: [
			WireMessage(
				role: .system, content: "You are Ada Kovač's coach.", toolCalls: [], toolCallId: nil
			),
			WireMessage(
				role: .user, content: "How did 1998-06-13 look?", toolCalls: [], toolCallId: nil),
			WireMessage(
				role: .assistant,
				content: "",
				toolCalls: [
					WireToolCall(id: "call_ada_1", name: .intervalsFetchAthlete, arguments: "{}")
				],
				toolCallId: nil
			),
			WireMessage(
				role: .tool,
				content: "{\"name\":\"Ada Kovač\"}",
				toolCalls: [],
				toolCallId: "call_ada_1"
			),
		],
		tools: tools
			? [
				ToolSchema(
					name: .intervalsFetchAthlete,
					description: "Fetch the athlete profile.",
					parameters: .object(["type": .string("object")])
				)
			]
			: [],
		deadline: .seconds(600)
	)
}

func parseFixture(_ name: String) async throws -> [TransportEvent] {
	try await transportEvents(OpenRouterSSEParser.events(from: fixture(name, ext: "sse")))
}

func transportEvents(_ stream: AsyncThrowingStream<TransportEvent, Error>) async throws
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

func objectValue(_ value: JSONValue?) throws -> [String: JSONValue] {
	guard case .object(let object) = value else {
		throw OpenRouterParseError.malformedSSE
	}
	return object
}

func arrayValue(_ value: JSONValue?) throws -> [JSONValue] {
	guard case .array(let items) = value else {
		throw OpenRouterParseError.malformedSSE
	}
	return items
}

func transportTextDeltas(in events: [TransportEvent]) -> [String] {
	events.compactMap { event in
		if case .textDelta(let text) = event {
			return text
		}
		return nil
	}
}

func toolCalls(in events: [TransportEvent]) -> [WireToolCall] {
	events.compactMap { event in
		if case .toolCall(let call) = event {
			return call
		}
		return nil
	}
}

func transportHTTPBody(from request: URLRequest) -> Data? {
	if let body = request.httpBody {
		return body
	}
	guard let stream = request.httpBodyStream else {
		return nil
	}
	stream.open()
	defer { stream.close() }
	let bufferSize = 1024
	let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
	defer { buffer.deallocate() }
	var data = Data()
	while stream.hasBytesAvailable {
		let read = stream.read(buffer, maxLength: bufferSize)
		if read <= 0 {
			break
		}
		data.append(buffer, count: read)
	}
	return data
}

func stubbedTransport() throws -> OpenRouterTransport {
	OpenRouterTransport(
		apiKey: "test-key",
		baseURL: try #require(URL(string: "https://openrouter.test/api/v1"))
	) { timeout in
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = timeout
		configuration.protocolClasses = [OpenRouterURLStub.self]
		return URLSession(configuration: configuration)
	}
}

final class OpenRouterURLStub: URLProtocol, @unchecked Sendable {
	struct Response: Sendable {
		var statusCode: Int
		var headers: [String: String]
		var body: Data

		static func ok(_ sse: String) -> Response {
			Response(
				statusCode: 200,
				headers: ["Content-Type": "text/event-stream"],
				body: Data(sse.utf8)
			)
		}
	}

	static let handler = Mutex<(@Sendable (URLRequest) -> Response)?>(nil)

	static func withHandler<T: Sendable>(
		_ handler: @escaping @Sendable (URLRequest) -> Response,
		perform: () async throws -> T
	) async throws -> T {
		let previous = Self.handler.withLock { current in
			let previous = current
			current = handler
			return previous
		}
		defer {
			Self.handler.withLock { $0 = previous }
		}
		return try await perform()
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let handler = Self.handler.withLock { $0 }
		guard let handler else {
			client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
			return
		}
		let response = handler(request)
		guard let url = request.url,
			let http = HTTPURLResponse(
				url: url,
				statusCode: response.statusCode,
				httpVersion: "HTTP/1.1",
				headerFields: response.headers
			)
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: response.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
