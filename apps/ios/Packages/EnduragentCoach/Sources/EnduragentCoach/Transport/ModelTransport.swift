import Foundation

public struct ModelID: Hashable, Sendable {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}
}

public enum AccessMethod: String, Hashable, Sendable {
	case credits
	case openRouterAccount
}

package struct ProviderCredential: Sendable, Equatable, CustomStringConvertible,
	CustomDebugStringConvertible, CustomReflectable
{
	package let secret: String
	package let method: AccessMethod

	package init(secret: String, method: AccessMethod) {
		self.secret = secret
		self.method = method
	}

	package var description: String { "ProviderCredential(redacted)" }
	package var debugDescription: String { description }
	package var customMirror: Mirror { Mirror(self, children: ["method": method]) }
}

package struct ResolvedAccess: Sendable, Equatable {
	package let credential: ProviderCredential
	package let model: ModelID

	package init(credential: ProviderCredential, model: ModelID) {
		self.credential = credential
		self.model = model
	}

	package var method: AccessMethod { credential.method }
}

package enum GenerateCharge: Sendable, Equatable {
	case chatAttempt
	case stepRecovery
	case compaction
	case memoryFlush
}

package struct CompletionRequest: Sendable, Equatable {
	package let credential: ProviderCredential
	package let model: ModelID
	package let attempt: AttemptID
	package let charge: GenerateCharge
	package let messages: [WireMessage]
	package let tools: [ToolSchema]
	package let deadline: Duration

	package init(
		access: ResolvedAccess,
		attempt: AttemptID,
		charge: GenerateCharge,
		messages: [WireMessage],
		tools: [ToolSchema],
		deadline: Duration
	) {
		self.credential = access.credential
		self.model = access.model
		self.attempt = attempt
		self.charge = charge
		self.messages = messages
		self.tools = tools
		self.deadline = deadline
	}
}

package struct WireMessage: Sendable, Equatable {
	package var role: Role
	package var content: String
	package var toolCalls: [WireToolCall]
	package var toolCallId: String?

	package enum Role: String, Sendable {
		case system
		case user
		case assistant
		case tool
	}
}

package struct WireToolCall: Sendable, Equatable {
	package var id: String
	package var name: ToolName
	package var arguments: String
}

package enum TransportEvent: Sendable, Equatable {
	case textDelta(String)
	case toolCall(WireToolCall)
	case heartbeat
	case finished(reason: FinishReason, usage: Usage)
}

public enum FinishReason: String, Sendable {
	case stop
	case toolCalls = "tool-calls"
	case length
	case contentFilter = "content_filter"
	case error
}

package struct Usage: Sendable, Equatable {
	package var inputTokens: Int
	package var outputTokens: Int
	package var cost: Double?
}

package protocol ModelTransport: Sendable {
	func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error>
}

public struct ModelService: Sendable {
	public static let openRouterAPI: URL = {
		guard let url = URL(string: "https://openrouter.ai/api/v1") else {
			fatalError("https://openrouter.ai/api/v1 is invalid")
		}
		return url
	}()

	package let makeTransport: @Sendable (DiagnosticsLog) -> any ModelTransport

	public static func openRouter(baseURL: URL) -> ModelService {
		ModelService { diagnostics in
			OpenRouterTransport(baseURL: baseURL, diagnostics: diagnostics)
		}
	}

	public static func scripted(_ fake: FakeModelTransport) -> ModelService {
		ModelService { _ in fake }
	}
}

package struct OpenRouterTransport: ModelTransport {
	private let baseURL: URL
	private let diagnostics: DiagnosticsLog
	private let makeSession: @Sendable (TimeInterval) -> URLSession

	package init(
		baseURL: URL,
		diagnostics: DiagnosticsLog,
		makeSession: @escaping @Sendable (TimeInterval) -> URLSession = Self.ephemeralSession
	) {
		self.baseURL = baseURL
		self.diagnostics = diagnostics
		self.makeSession = makeSession
	}

	package func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error>
	{
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					try await exchange(request) { event in
						continuation.yield(event)
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: settle(error, of: request))
				}
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	private func exchange(
		_ request: CompletionRequest,
		yield: @escaping @Sendable (TransportEvent) -> Void
	) async throws {
		let session = makeSession(request.deadline.timeInterval)
		defer { session.finishTasksAndInvalidate() }
		let urlRequest: URLRequest
		do {
			urlRequest = try OpenRouterHTTP.urlRequest(baseURL: baseURL, request: request)
		} catch {
			throw ExchangeFault.unencodable(String(describing: error))
		}
		let (bytes, response) = try await session.bytes(for: urlRequest)
		guard let http = response as? HTTPURLResponse else {
			throw ProviderFailure.malformedStream
		}
		guard (200..<300).contains(http.statusCode) else {
			throw ExchangeFault.rejected(
				status: http.statusCode,
				headers: OpenRouterHTTP.headers(of: http),
				body: try await OpenRouterHTTP.utf8String(from: bytes)
			)
		}
		try await OpenRouterSSEParser.parse(lines: bytes.lines, yield: yield)
	}

	private func settle(_ error: any Error, of request: CompletionRequest) -> any Error {
		let failure: ProviderFailure
		let detail: String
		switch error {
		case is CancellationError:
			return CancellationError()
		case let urlError as URLError where urlError.code == .cancelled:
			return CancellationError()
		case ExchangeFault.rejected(let status, let headers, let body):
			failure = ProviderFailure(status: status, headers: headers, body: body)
			detail = "HTTP \(status): \(body)"
		case ExchangeFault.unencodable(let reason):
			failure = .invalidRequest
			detail = reason
		case let urlError as URLError:
			failure = ProviderFailure(urlError)
			detail = "URLError \(urlError.code.rawValue)"
		case let parsed as ProviderFailure:
			failure = parsed
			detail = ""
		default:
			failure = .network
			detail = String(describing: error)
		}
		diagnostics.record(
			.providerFailure(request.attempt, failure, detail: detail),
			redacting: [request.credential.secret]
		)
		return failure
	}

	package static let ephemeralSession: @Sendable (TimeInterval) -> URLSession = { timeout in
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = timeout
		return URLSession(configuration: configuration)
	}
}

private enum ExchangeFault: Error {
	case unencodable(String)
	case rejected(status: Int, headers: [String: String], body: String)
}

package enum OpenRouterHTTP {
	package static func body(for request: CompletionRequest) -> JSONValue {
		var object: [String: JSONValue] = [
			"model": .string(request.model.rawValue),
			"messages": .array(request.messages.map(encode(message:))),
			"stream": .bool(true),
			"usage": .object(["include": .bool(true)]),
		]
		if !request.tools.isEmpty {
			object["tools"] = .array(request.tools.map(encode(tool:)))
			object["tool_choice"] = .string("auto")
		}
		return .object(object)
	}

	package static func urlRequest(baseURL: URL, request: CompletionRequest) throws -> URLRequest {
		var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
		urlRequest.httpMethod = "POST"
		urlRequest.setValue(
			"Bearer \(request.credential.secret)", forHTTPHeaderField: "Authorization")
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		urlRequest.httpBody = try OpenRouterJSON.data(from: body(for: request))
		return urlRequest
	}

	package static func headers(of response: HTTPURLResponse) -> [String: String] {
		var headers: [String: String] = [:]
		for (key, value) in response.allHeaderFields {
			if let name = key.base as? String, let text = value as? String {
				headers[name] = text
			}
		}
		return headers
	}

	package static func utf8String(from bytes: URLSession.AsyncBytes) async throws -> String {
		var data = Data()
		for try await byte in bytes {
			data.append(byte)
		}
		return String(decoding: data, as: UTF8.self)
	}

	private static func encode(message: WireMessage) -> JSONValue {
		var object: [String: JSONValue] = [
			"role": .string(message.role.rawValue),
			"content": .string(message.content),
		]
		if !message.toolCalls.isEmpty {
			object["tool_calls"] = .array(message.toolCalls.map(encode(toolCall:)))
		}
		if let toolCallId = message.toolCallId {
			object["tool_call_id"] = .string(toolCallId)
		}
		return .object(object)
	}

	private static func encode(toolCall: WireToolCall) -> JSONValue {
		.object([
			"id": .string(toolCall.id),
			"type": .string("function"),
			"function": .object([
				"name": .string(toolCall.name.rawValue),
				"arguments": .string(toolCall.arguments),
			]),
		])
	}

	private static func encode(tool: ToolSchema) -> JSONValue {
		.object([
			"type": .string("function"),
			"function": .object([
				"name": .string(tool.name.rawValue),
				"description": .string(tool.description),
				"parameters": tool.parameters,
			]),
		])
	}
}

package enum OpenRouterJSON {
	package static func data(from value: JSONValue) throws -> Data {
		try JSONSerialization.data(withJSONObject: jsonObject(from: value))
	}

	package static func jsonObject(from value: JSONValue) -> Any {
		switch value {
		case .null:
			return NSNull()
		case .bool(let value):
			return value
		case .number(let value):
			return value
		case .string(let value):
			return value
		case .array(let values):
			return values.map(jsonObject(from:))
		case .object(let values):
			return values.mapValues(jsonObject(from:))
		}
	}
}
