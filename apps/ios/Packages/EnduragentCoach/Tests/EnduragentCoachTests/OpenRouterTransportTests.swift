import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct OpenRouterTransportTests {
	@Test func bodyOmitsTemperatureAndIncludesUsage() throws {
		let body = OpenRouterHTTP.body(for: sampleRequest(tools: true))
		let object = try objectValue(body)
		#expect(object["temperature"] == nil)
		#expect(object["model"] == .string(testModel.rawValue))
		#expect(object["stream"] == .bool(true))
		#expect(object["usage"] == .object(["include": .bool(true)]))
		#expect(object["tool_choice"] == .string("auto"))
		let tools = try arrayValue(object["tools"])
		#expect(tools.count == 1)
		let tool = try objectValue(tools[0])
		#expect(tool["type"] == .string("function"))
		let function = try objectValue(tool["function"])
		#expect(function["name"] == .string("intervals_fetch_athlete"))
		#expect(function["description"] == .string("Fetch the athlete profile."))
		#expect(function["parameters"] == .object(["type": .string("object")]))
		let messages = try arrayValue(object["messages"])
		#expect(messages.count == 4)
		let assistant = try objectValue(messages[2])
		#expect(assistant["role"] == .string("assistant"))
		let toolCalls = try arrayValue(assistant["tool_calls"])
		let call = try objectValue(toolCalls[0])
		#expect(call["id"] == .string("call_ada_1"))
		#expect(call["type"] == .string("function"))
		let callFunction = try objectValue(call["function"])
		#expect(callFunction["name"] == .string("intervals_fetch_athlete"))
		#expect(callFunction["arguments"] == .string("{}"))
		let toolMessage = try objectValue(messages[3])
		#expect(toolMessage["role"] == .string("tool"))
		#expect(toolMessage["tool_call_id"] == .string("call_ada_1"))
		#expect(toolMessage["content"] == .string("{\"name\":\"Ada Kovač\"}"))
	}

	@Test func bodyOmitsToolsWhenEmpty() throws {
		let body = OpenRouterHTTP.body(for: sampleRequest(tools: false))
		let object = try objectValue(body)
		#expect(object["tools"] == nil)
		#expect(object["tool_choice"] == nil)
		#expect(object["temperature"] == nil)
	}

	@Test func parserConcatenatesFragmentedToolCallArguments() async throws {
		let events = try await parseFixture("openrouter-tool-call-fragments")
		let calls = toolCalls(in: events)
		#expect(calls.count == 1)
		#expect(calls[0].id == "call_ada_week")
		#expect(calls[0].name == .intervalsFetchActivities)
		#expect(calls[0].arguments == "{\"days\":7}")
		guard case .finished(let reason, let usage) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .toolCalls)
		#expect(usage.inputTokens == 18)
		#expect(usage.outputTokens == 12)
		#expect(usage.cost == 0.5)
	}

	@Test func parserYieldsParallelToolCallsByIndex() async throws {
		let events = try await parseFixture("openrouter-parallel-tool-calls")
		let calls = toolCalls(in: events)
		#expect(calls.count == 2)
		#expect(calls[0].id == "call_ada_athlete")
		#expect(calls[0].name == .intervalsFetchAthlete)
		#expect(calls[0].arguments == "{}")
		#expect(calls[1].id == "call_ada_wellness")
		#expect(calls[1].name == .intervalsFetchWellness)
		#expect(calls[1].arguments == "{\"oldest\":\"1998-06-01\",\"newest\":\"1998-06-13\"}")
	}

	@Test func parserYieldsTextUsageAndNoTemperatureLeak() async throws {
		let events = try await parseFixture("openrouter-text-usage")
		#expect(textDeltas(in: events) == ["Your week ", "looked strong, Ada."])
		guard case .finished(let reason, let usage) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .stop)
		#expect(usage.inputTokens == 24)
		#expect(usage.outputTokens == 8)
		#expect(usage.cost == 0.25)
	}

	@Test func parserTreatsReasoningAndKeepAlivesAsHeartbeats() async throws {
		let events = try await parseFixture("openrouter-reasoning-keepalive")
		#expect(events.filter { $0 == .heartbeat }.count >= 3)
		#expect(textDeltas(in: events) == ["Rest on Sunday."])
		guard case .finished(let reason, _) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .stop)
	}

	@Test func parserMapsLengthFinishReason() async throws {
		let events = try await parseFixture("openrouter-finish-length")
		guard case .finished(let reason, let usage) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .length)
		#expect(usage.inputTokens == 40)
		#expect(usage.outputTokens == 20)
	}

	@Test func parserMapsErrorFinishReasonAndKeepsPartialText() async throws {
		let events = try await parseFixture("openrouter-finish-error")
		#expect(textDeltas(in: events) == ["Tomorrow's ride is queued."])
		guard case .finished(let reason, let usage) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .error)
		#expect(usage.inputTokens == 40)
		#expect(usage.outputTokens == 8)
	}

	@Test func parserMapsContentFilterFinishReason() async throws {
		let events = try await parseFixture("openrouter-finish-content-filter")
		#expect(textDeltas(in: events) == ["Stopped."])
		guard case .finished(let reason, _) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .contentFilter)
	}

	@Test func parserSumsUsageAndCostAcrossSteps() async throws {
		let events = try await parseFixture("openrouter-usage-sum")
		guard case .finished(_, let usage) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(usage.inputTokens == 20)
		#expect(usage.outputTokens == 3)
		#expect(usage.cost == 0.75)
	}

	@Test func parserOmitsCostWhenAnyStepLacksIt() async throws {
		let events = try await parseFixture("openrouter-usage-partial-cost")
		guard case .finished(_, let usage) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(usage.inputTokens == 8)
		#expect(usage.outputTokens == 3)
		#expect(usage.cost == nil)
	}

	@Test func streamPostsOnceWithBearerAndNoReferer() async throws {
		let sse = try fixture("openrouter-text-usage", ext: "sse")
		let state = HTTPCapture()
		let transport = try OpenRouterStub.transport { request in
			state.record(request)
			return .reply(.sse(sse))
		}
		let events = try await collect(transport.stream(sampleRequest(tools: false)))
		#expect(state.posts == 1)
		let request = try #require(state.request)
		#expect(request.httpMethod == "POST")
		#expect(request.url?.path() == "/api/v1/chat/completions")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testKey)")
		#expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
		#expect(request.value(forHTTPHeaderField: "Referer") == nil)
		#expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == nil)
		let bodyData = try #require(httpBody(from: request))
		let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
		#expect(body?["temperature"] == nil)
		#expect(body?["stream"] as? Bool == true)
		#expect(body?["model"] as? String == testModel.rawValue)
		#expect(textDeltas(in: events) == ["Your week ", "looked strong, Ada."])
	}

	@Test func streamUsesDeadlineAsRequestTimeout() async throws {
		let sse = try fixture("openrouter-text-usage", ext: "sse")
		let state = TimeoutCapture()
		let transport = try OpenRouterStub.transport(onSession: { state.value = $0 }) { _ in
			.reply(.sse(sse))
		}
		_ = try await collect(
			transport.stream(
				testRequest(
					[WireMessage(role: .user, content: "Hi Ada", toolCalls: [], toolCallId: nil)],
					deadline: .seconds(45))))
		#expect(state.value == 45)
	}

	@Test func streamThrowsOnlyProviderFailure() async throws {
		let malformed = try fixture("openrouter-malformed-chunk", ext: "sse")
		let outcomes: [OpenRouterStub.Outcome] =
			[400, 401, 402, 403, 404, 408, 418, 429, 500, 502, 503, 302].map {
				.reply(.json($0, #"{"error":{"message":"refused","code":\#($0)}}"#))
			} + [
				.fail(.timedOut), .fail(.notConnectedToInternet), .fail(.networkConnectionLost),
				.fail(.cannotFindHost), .fail(.cannotConnectToHost), .fail(.dnsLookupFailed),
				.fail(.secureConnectionFailed), .fail(.badServerResponse),
				.reply(.sse(malformed)), .reply(.sse("data: [DONE]\n")),
			]
		for outcome in outcomes {
			let transport = try OpenRouterStub.transport { _ in outcome }
			do {
				_ = try await collect(transport.stream(sampleRequest(tools: false)))
				Issue.record("expected a failure for \(outcome)")
			} catch {
				#expect(error is ProviderFailure, "\(outcome) threw \(type(of: error))")
			}
		}
	}

	@Test func credentialNeverAppearsInDescription() {
		let request = sampleRequest(tools: true)
		var dumped = ""
		dump(request, to: &dumped)
		let renderings = [
			request.credential.description,
			request.credential.debugDescription,
			String(describing: request.credential),
			String(reflecting: request.credential),
			String(describing: request),
			String(reflecting: request),
			"\(testAccess)",
			dumped,
		]
		for rendering in renderings {
			#expect(!rendering.contains(testKey), "\(rendering)")
		}
		#expect(request.credential.description == "ProviderCredential(redacted)")
	}
}

private final class HTTPCapture: Sendable {
	private let state = Mutex<(request: URLRequest?, count: Int)>((nil, 0))

	var request: URLRequest? {
		state.withLock { $0.request }
	}

	var posts: Int {
		state.withLock { $0.count }
	}

	func record(_ request: URLRequest) {
		state.withLock { snapshot in
			snapshot.request = request
			snapshot.count += 1
		}
	}
}

private final class TimeoutCapture: Sendable {
	private let stored = Mutex<TimeInterval?>(nil)

	var value: TimeInterval? {
		get { stored.withLock { $0 } }
		set { stored.withLock { $0 = newValue } }
	}
}

private func sampleRequest(tools: Bool) -> CompletionRequest {
	testRequest(
		[
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
			: []
	)
}

private func parseFixture(_ name: String) async throws -> [TransportEvent] {
	try await collect(OpenRouterSSEParser.events(from: fixture(name, ext: "sse")))
}

private struct UnexpectedJSONShape: Error {
	let value: JSONValue?
}

private func objectValue(_ value: JSONValue?) throws -> [String: JSONValue] {
	guard case .object(let object) = value else {
		throw UnexpectedJSONShape(value: value)
	}
	return object
}

private func arrayValue(_ value: JSONValue?) throws -> [JSONValue] {
	guard case .array(let items) = value else {
		throw UnexpectedJSONShape(value: value)
	}
	return items
}

private func toolCalls(in events: [TransportEvent]) -> [WireToolCall] {
	events.compactMap { event in
		if case .toolCall(let call) = event {
			return call
		}
		return nil
	}
}

private func httpBody(from request: URLRequest) -> Data? {
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
