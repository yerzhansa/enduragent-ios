import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct FakeModelTransportTests {
	@Test func streamReplaysScriptAcrossTwoRequests() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.text("Ada rode Saturday."),
				.finish(reason: .stop),
				.toolCall(name: "intervals_fetch_athlete", arguments: "{}"),
				.finish(reason: .toolCalls),
			], otherwise: transport.respond)
		let firstRequest = testRequest([
			WireMessage(role: .user, content: "How was 1998-06-13?", toolCalls: [], toolCallId: nil)
		])
		let secondRequest = testRequest(
			[
				WireMessage(
					role: .user, content: "Fetch the athlete.", toolCalls: [], toolCallId: nil)
			],
			tools: [
				ToolSchema(
					name: .intervalsFetchAthlete,
					description: "Fetch the athlete profile.",
					parameters: .object(["type": .string("object")])
				)
			]
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
		#expect(call.name == "intervals_fetch_athlete")
		#expect(call.arguments == "{}")
		#expect(
			second.last
				== .finished(
					reason: .toolCalls, usage: Usage(inputTokens: 0, outputTokens: 0, cost: nil)))

		#expect(transport.requests == [firstRequest, secondRequest])
	}

	@Test func hangingStreamFinishesWhenCancelled() async throws {
		let transport = FakeModelTransport()
		transport.respond = { _ in ScriptedReply([.hang]) }
		let request = testRequest(
			[WireMessage(role: .user, content: "Hang", toolCalls: [], toolCallId: nil)],
			deadline: .seconds(30))
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
		transport.respond = ScriptedReply.sequence(
			[
				.text("one"),
				.finish(reason: .stop),
				.text("two"),
				.finish(reason: .length),
			], otherwise: transport.respond)
		let request = testRequest(
			[WireMessage(role: .user, content: "Hi Ada", toolCalls: [], toolCallId: nil)],
			deadline: .seconds(30))
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
		transport.respond = ScriptedReply.sequence(
			[.text("one"), .text("two"), .finish(reason: .stop)], for: .chat,
			deltaDelay: delay, otherwise: transport.respond)
		let clock = ContinuousClock()
		let started = clock.now
		var arrivals: [ContinuousClock.Instant] = []
		for try await _ in transport.stream(request("Slowly")) {
			arrivals.append(clock.now)
		}
		#expect(arrivals.count == 3)
		for (index, arrival) in arrivals.enumerated() {
			#expect(arrival - started >= delay * (index + 1))
		}
	}

	@Test func scriptedFailureFailsTheRequestThatReachesIt() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.fail(.http(status: 500)), .text("after"), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		await #expect(throws: ProviderFailure.serverError(status: 500, retryAfter: nil)) {
			_ = try await collect(transport.stream(request("First")))
		}
		let second = try await collect(transport.stream(request("Second")))
		#expect(textDeltas(in: second) == ["after"])
		#expect(transport.requestCount == 2)
	}

	@Test func failureAfterTextStreamsTheTextThenThrows() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is "), .fail(.connection(.networkConnectionLost))], for: .chat,
			otherwise: transport.respond)
		var received: [TransportEvent] = []
		await #expect(throws: ProviderFailure.network) {
			for try await event in transport.stream(request("Thursday?")) {
				received.append(event)
			}
		}
		#expect(textDeltas(in: received) == ["Thursday is "])
	}

	@Test func summariesAndFlushesReadTheirOwnScripts() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.fail(.http(status: 429)), .text("reply"), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[
				.text("summary"), .finish(reason: .stop), .text("dropped"), .finish(reason: .stop),
			], for: .summary, otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("flush"), .finish(reason: .stop)], for: .flush, otherwise: transport.respond)
		let summary = try await collect(transport.stream(maintenance(.compaction)))
		#expect(textDeltas(in: summary) == ["summary"])
		await #expect(throws: ProviderFailure.rateLimited(retryAfter: nil)) {
			_ = try await collect(transport.stream(request("Chat")))
		}
		let flush = try await collect(transport.stream(maintenance(.memoryFlush)))
		#expect(textDeltas(in: flush) == ["flush"])
		let dropped = try await collect(transport.stream(maintenance(.droppedSummary)))
		#expect(textDeltas(in: dropped) == ["dropped"])
		#expect(try await collect(transport.stream(maintenance(.memoryFlush))).isEmpty)
		#expect(textDeltas(in: try await collect(transport.stream(request("Chat")))) == ["reply"])
	}

	@Test func everyRequestKeepsItsAttemptQuestionAndStep() async throws {
		let transport = FakeModelTransport { request in
			ScriptedReply([.text("\(request.text):\(request.step)"), .finish(reason: .stop)])
		}
		let first = request("Thursday?")
		#expect(textDeltas(in: try await collect(transport.stream(first))) == ["Thursday?:0"])
		let second = testRequest(
			first.messages + [
				WireMessage(role: .user, content: "Continue", toolCalls: [], toolCallId: nil)
			])
		#expect(textDeltas(in: try await collect(transport.stream(second))) == ["Thursday?:1"])
	}

	@Test func aLaterFlushReadsItsOwnMessagesInsteadOfTheLatestChat() async throws {
		let transport = FakeModelTransport { request in
			ScriptedReply([.text(request.text), .finish(reason: .stop)])
		}
		_ = try await collect(transport.stream(request("A later chat")))
		let flush = CompletionRequest(
			access: testAccess, attempt: AttemptID(ulid: fixedUlid(902)), charge: .memoryFlush,
			messages: [
				WireMessage(
					role: .user, content: "The rows being flushed", toolCalls: [], toolCallId: nil)
			], tools: [], deadline: .seconds(30))
		#expect(
			textDeltas(in: try await collect(transport.stream(flush)))
				== ["The rows being flushed"])
	}

	private func maintenance(_ charge: GenerateCharge) -> CompletionRequest {
		CompletionRequest(
			access: testAccess, attempt: AttemptID(ulid: fixedUlid(901)), charge: charge,
			messages: [], tools: [], deadline: .seconds(30))
	}

	@Test func scriptedHangStreamsThenWaitsForCancellation() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is "), .hang, .text("next"), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let stream = transport.stream(request("Hang"))
		let task = Task {
			var texts: [String] = []
			for try await event in stream {
				if case .textDelta(let text) = event {
					texts.append(text)
				}
			}
			return texts
		}
		try await Task.sleep(for: .milliseconds(50))
		task.cancel()
		#expect(try await task.value == ["Thursday is "])
		let next = try await collect(transport.stream(request("Again")))
		#expect(textDeltas(in: next) == ["next"])
	}

	@Test func scriptedFailuresParseTheWireLikeTheTransport() {
		#expect(
			ScriptedFailure.http(status: 429, headers: ["Retry-After": "7"]).failure
				== .rateLimited(retryAfter: .seconds(7)))
		#expect(ScriptedFailure.http(status: 401).failure == .credentialRejected(status: 401))
		#expect(ScriptedFailure.http(status: 402).failure == .accessExhausted)
		#expect(ScriptedFailure.connection(.notConnectedToInternet).failure == .network)
		#expect(ScriptedFailure.connection(.timedOut).failure == .timeout(.request))
	}
}

private func request(_ content: String) -> CompletionRequest {
	testRequest(
		[WireMessage(role: .user, content: content, toolCalls: [], toolCallId: nil)],
		deadline: .seconds(30))
}
