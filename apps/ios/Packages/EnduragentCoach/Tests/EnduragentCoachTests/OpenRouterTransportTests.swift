import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct OpenRouterTransportTests {
	@Test func bodyOmitsTemperatureAndIncludesUsage() throws {
		let body = OpenRouterHTTP.body(for: sampleRequest(tools: true))
		let object = try objectValue(body)
		#expect(object["temperature"] == nil)
		#expect(object["model"] == .string(CompletionRequest.openRouterModel))
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
		#expect(transportTextDeltas(in: events) == ["Your week ", "looked strong, Ada."])
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
		#expect(transportTextDeltas(in: events) == ["Rest on Sunday."])
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
		#expect(transportTextDeltas(in: events) == ["Tomorrow's ride is queued."])
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
		#expect(transportTextDeltas(in: events) == ["Stopped."])
		guard case .finished(let reason, _) = events.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .contentFilter)
	}

	@Test func parserThrowsOnUnknownFinishReason() async {
		await #expect(throws: UnknownFinishReasonError.self) {
			_ = try await parseFixture("openrouter-finish-unknown")
		}
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

	@Suite(.serialized)
	struct HTTP {
		@Test func streamPostsOnceWithBearerAndNoReferer() async throws {
			let sse = try fixture("openrouter-text-usage", ext: "sse")
			let state = HTTPCapture()
			let transport = try stubbedTransport()
			let events = try await OpenRouterURLStub.withHandler({ request in
				state.record(request)
				return .ok(sse)
			}) {
				try await transportEvents(transport.stream(sampleRequest(tools: false)))
			}
			#expect(state.posts == 1)
			let request = try #require(state.request)
			#expect(request.httpMethod == "POST")
			#expect(
				request.url?.absoluteString == "https://openrouter.test/api/v1/chat/completions")
			#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
			#expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
			#expect(request.value(forHTTPHeaderField: "Referer") == nil)
			#expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == nil)
			let bodyData = try #require(transportHTTPBody(from: request))
			let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
			#expect(body?["temperature"] == nil)
			#expect(body?["stream"] as? Bool == true)
			#expect(transportTextDeltas(in: events) == ["Your week ", "looked strong, Ada."])
		}

		@Test func streamUsesDeadlineAsRequestTimeout() async throws {
			let sse = try fixture("openrouter-text-usage", ext: "sse")
			let state = TimeoutCapture()
			let transport = OpenRouterTransport(
				apiKey: "test-key",
				baseURL: try #require(URL(string: "https://openrouter.test/api/v1"))
			) { value in
				state.value = value
				let configuration = URLSessionConfiguration.ephemeral
				configuration.timeoutIntervalForRequest = value
				configuration.protocolClasses = [OpenRouterURLStub.self]
				return URLSession(configuration: configuration)
			}
			try await OpenRouterURLStub.withHandler({ _ in .ok(sse) }) {
				_ = try await transportEvents(
					transport.stream(
						CompletionRequest.openRouter(
							messages: [
								WireMessage(
									role: .user, content: "Hi Ada", toolCalls: [], toolCallId: nil)
							],
							tools: [],
							deadline: .seconds(45)
						)
					)
				)
			}
			#expect(state.value == 45)
		}

		@Test func streamSurfaces401AsProviderAuthError() async throws {
			let body = try fixture("openrouter-unauthorized", ext: "json")
			let state = HTTPCapture()
			let transport = try stubbedTransport()
			do {
				_ = try await OpenRouterURLStub.withHandler({ request in
					state.record(request)
					return OpenRouterURLStub.Response(
						statusCode: 401,
						headers: ["Content-Type": "application/json"],
						body: Data(body.utf8)
					)
				}) {
					try await transportEvents(transport.stream(sampleRequest(tools: false)))
				}
				Issue.record("expected provider auth error")
			} catch let error as ProviderAuthError {
				#expect(error.statusCode == 401)
				#expect(error.body.contains("User not found."))
			}
			#expect(state.posts == 1)
		}
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
