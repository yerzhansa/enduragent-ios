import Testing

@testable import EnduragentCoach

@Suite struct FakeModelTransportTests {
	@Test func streamReplaysScriptAcrossTwoRequests() async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.text("Ada rode Saturday."),
			.finish(reason: .stop),
			.toolCall(name: "intervals_fetch_athlete", arguments: "{}"),
			.finish(reason: .toolCalls),
		]
		let firstRequest = CompletionRequest.openRouter(
			messages: [
				WireMessage(
					role: .user, content: "How was 1998-06-13?", toolCalls: [], toolCallId: nil)
			],
			tools: [],
			deadline: .seconds(600)
		)
		let secondRequest = CompletionRequest.openRouter(
			messages: [
				WireMessage(
					role: .user, content: "Fetch the athlete.", toolCalls: [], toolCallId: nil)
			],
			tools: [
				ToolSchema(
					name: .intervalsFetchAthlete,
					description: "Fetch the athlete profile.",
					parameters: .object(["type": .string("object")])
				)
			],
			deadline: .seconds(600)
		)

		let first = try await collect(transport.stream(firstRequest))
		#expect(
			first == [
				.textDelta("Ada rode Saturday."),
				.finished(reason: .stop, usage: Usage(inputTokens: 0, outputTokens: 0, cost: nil)),
			])

		let second = try await collect(transport.stream(secondRequest))
		#expect(second.count == 2)
		guard case .toolCall(let call) = second.first else {
			Issue.record("expected tool call")
			return
		}
		#expect(!call.id.isEmpty)
		#expect(call.name == .intervalsFetchAthlete)
		#expect(call.arguments == "{}")
		#expect(
			second.last
				== .finished(
					reason: .toolCalls, usage: Usage(inputTokens: 0, outputTokens: 0, cost: nil)))

		#expect(transport.requests == [firstRequest, secondRequest])
		#expect(transport.script.isEmpty)
	}

	@Test func hangingStreamFinishesWhenCancelled() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let request = CompletionRequest.openRouter(
			messages: [
				WireMessage(role: .user, content: "Hang", toolCalls: [], toolCallId: nil)
			],
			tools: [],
			deadline: .seconds(30)
		)
		let task = Task {
			var count = 0
			for try await _ in transport.stream(request) {
				count += 1
			}
			return count
		}
		try await Task.sleep(for: .milliseconds(20))
		task.cancel()
		let count = try await task.value
		#expect(count == 0)
	}

	@Test func streamStopsAtEachFinish() async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.text("one"),
			.finish(reason: .stop),
			.text("two"),
			.finish(reason: .length),
		]
		let request = CompletionRequest.openRouter(
			messages: [
				WireMessage(role: .user, content: "Hi Ada", toolCalls: [], toolCallId: nil)
			],
			tools: [],
			deadline: .seconds(30)
		)
		let first = try await collect(transport.stream(request))
		#expect(textDeltas(in: first) == ["one"])
		let second = try await collect(transport.stream(request))
		#expect(textDeltas(in: second) == ["two"])
		guard case .finished(let reason, _) = second.last else {
			Issue.record("expected finished")
			return
		}
		#expect(reason == .length)
	}

	@Test func deltaDelayPausesBeforeEachEvent() async throws {
		let delay = Duration.milliseconds(60)
		let transport = FakeModelTransport()
		transport.deltaDelay = delay
		transport.script = [.text("one"), .text("two"), .finish(reason: .stop)]
		let clock = ContinuousClock()
		let started = clock.now
		var arrivals: [ContinuousClock.Instant] = []
		for try await _ in transport.stream(request("Slowly")) {
			arrivals.append(clock.now)
		}
		#expect(arrivals.count == 3)
		var previous = started
		for (index, arrival) in arrivals.enumerated() {
			#expect(arrival - started >= delay * (index + 1))
			#expect(arrival - previous >= delay / 2)
			previous = arrival
		}
	}

	@Test func failureQueueIsConsumedBeforeTheScript() async throws {
		let transport = FakeModelTransport()
		transport.failures = [OpenRouterHTTPError(statusCode: 500, body: "")]
		transport.script = [.text("after"), .finish(reason: .stop)]
		await #expect(throws: OpenRouterHTTPError(statusCode: 500, body: "")) {
			_ = try await collect(transport.stream(request("First")))
		}
		#expect(transport.failures.isEmpty)
		let second = try await collect(transport.stream(request("Second")))
		#expect(textDeltas(in: second) == ["after"])
		#expect(transport.requests.count == 2)
	}
}

private func request(_ content: String) -> CompletionRequest {
	CompletionRequest.openRouter(
		messages: [WireMessage(role: .user, content: content, toolCalls: [], toolCallId: nil)],
		tools: [],
		deadline: .seconds(30)
	)
}

private func collect(_ stream: AsyncThrowingStream<TransportEvent, Error>) async throws
	-> [TransportEvent]
{
	var events: [TransportEvent] = []
	for try await event in stream {
		events.append(event)
	}
	return events
}

private func textDeltas(in events: [TransportEvent]) -> [String] {
	events.compactMap { event in
		if case .textDelta(let text) = event {
			return text
		}
		return nil
	}
}
