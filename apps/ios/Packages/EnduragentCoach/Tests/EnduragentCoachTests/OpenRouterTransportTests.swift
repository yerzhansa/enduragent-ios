import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct OpenRouterTransportTests {
	@Test func catalogRecipientRestrictsHTTPRouting() async throws {
		let provider = try NamedProvider(name: "Published Host", routingSlug: "published-host")
		let request = CompletionRequest(
			access: ResolvedAccess(
				credential: ProviderCredential(
					secret: "synthetic-account", method: .openRouterAccount),
				model: ModelID(rawValue: "author/model"), provider: provider),
			attempt: AttemptID(ulid: fixedUlid(901)), charge: .chatAttempt,
			messages: [], tools: [], deadline: .seconds(30))
		let transport = try OpenRouterStub.transport { received in
			do {
				let body = try #require(openRouterHTTPBody(from: received))
				let object = try JSONValue.parse(String(decoding: body, as: UTF8.self)).objectFields
				#expect(object["model"] == .string("author/model"))
				#expect(
					object["provider"]
						== .object([
							"only": .array([.string("published-host")]),
							"allow_fallbacks": .bool(false),
						]))
			} catch {
				Issue.record(error)
			}
			return .reply(
				.sse(
					#"data: {"choices":[{"delta":{"content":"Host answered."},"finish_reason":"stop"}]}"#
						+ "\ndata: [DONE]\n"))
		}
		let events = try await collect(transport.stream(request))
		#expect(textDeltas(in: events) == ["Host answered."])
	}

	@Test(arguments: ["\n", "\r\n", "\r"], [false, true])
	func streamKeepsUnicodeSeparators(lineEnding: String, fragmented: Bool) async throws {
		let text = "Ride\u{2028}recover\u{2029}repeat\u{0085}rest"
		let sse = [
			": keep-alive",
			"",
			#"data: {"choices":[{"delta":{"content":"\#(text)"}}]}"#,
			"",
			#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
			"",
			"data: [DONE]",
			"",
			"",
		].joined(separator: lineEnding)
		let transport = try OpenRouterStub.transport { _ in
			.reply(.sse(sse, fragmented: fragmented))
		}
		let events = try await collect(transport.stream(sampleRequest(tools: false)))
		#expect(
			events == [
				.heartbeat,
				.textDelta(text),
				.heartbeat,
				.finished(reason: .stop, usage: Usage(inputTokens: 0, outputTokens: 0, cost: nil)),
			])
	}

	@Test func parserPreservesUnknownToolNames() async throws {
		let sse =
			#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"unknown_call","function":{"name":"invented_tool","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
		let transport = try OpenRouterStub.transport { _ in .reply(.sse(sse + "\ndata: [DONE]\n")) }
		let events = try await collect(transport.stream(sampleRequest(tools: false)))
		let call = try #require(toolCalls(in: events).first)
		#expect(call.name == "invented_tool")
		#expect(call.id == "unknown_call")
		#expect(call.arguments == "{}")
	}

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
		#expect(calls[0].name == "intervals_fetch_activities")
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
		#expect(calls[0].name == "intervals_fetch_athlete")
		#expect(calls[0].arguments == "{}")
		#expect(calls[1].id == "call_ada_wellness")
		#expect(calls[1].name == "intervals_fetch_wellness")
		#expect(calls[1].arguments == "{\"oldest\":\"1998-06-01\",\"newest\":\"1998-06-13\"}")
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

	@Test(arguments: [
		FinishRow(
			"openrouter-text-usage", text: ["Your week ", "looked strong, Ada."], reason: .stop,
			usage: Usage(inputTokens: 24, outputTokens: 8, cost: 0.25)),
		FinishRow(
			"openrouter-finish-length", text: ["Ada's June 1998 block ", "was cut short."],
			reason: .length, usage: Usage(inputTokens: 40, outputTokens: 20, cost: 0.5)),
		FinishRow(
			"openrouter-finish-error", text: ["Tomorrow's ride is queued."], reason: .error,
			usage: Usage(inputTokens: 40, outputTokens: 8, cost: 0.2)),
		FinishRow(
			"openrouter-finish-content-filter", text: ["Stopped."], reason: .contentFilter,
			usage: Usage(inputTokens: 0, outputTokens: 0, cost: nil)),
		FinishRow(
			"openrouter-usage-sum", text: ["Hi ", "Ada"], reason: .stop,
			usage: Usage(inputTokens: 20, outputTokens: 3, cost: 0.75)),
		FinishRow(
			"openrouter-usage-partial-cost", text: ["Hi", " Ada"], reason: .stop,
			usage: Usage(inputTokens: 8, outputTokens: 3, cost: nil)),
	])
	func parserYieldsTextFinishReasonAndSummedUsage(row: FinishRow) async throws {
		let events = try await parseFixture(row.fixture)
		#expect(textDeltas(in: events) == row.text)
		#expect(events.last == .finished(reason: row.reason, usage: row.usage))
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
		let bodyData = try #require(openRouterHTTPBody(from: request))
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

	@Test(.timeLimit(.minutes(1))) func errorBodyReadStopsAtItsLimit() async throws {
		let endless = AsyncStream<UInt8>(unfolding: { UInt8(ascii: "x") })
		let body = try await OpenRouterHTTP.errorBody(from: endless)
		#expect(body.count == OpenRouterHTTP.errorBodyLimit)
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
					WireToolCall(id: "call_ada_1", name: "intervals_fetch_athlete", arguments: "{}")
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
	let sse = try fixture(name, ext: "sse")
	let transport = try OpenRouterStub.transport { _ in .reply(.sse(sse)) }
	return try await collect(transport.stream(sampleRequest(tools: false)))
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

struct FinishRow: Sendable, CustomTestStringConvertible {
	let fixture: String
	let text: [String]
	let reason: FinishReason
	let usage: Usage

	init(_ fixture: String, text: [String], reason: FinishReason, usage: Usage) {
		self.fixture = fixture
		self.text = text
		self.reason = reason
		self.usage = usage
	}

	var testDescription: String { fixture }
}
