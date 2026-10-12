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

	@Test func deltaDelaySleepsOncePerEvent() async throws {
		let delay = Duration.milliseconds(60)
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let transport = FakeModelTransport(clock: clock)
		transport.respond = ScriptedReply.sequence(
			[.text("one"), .text("two"), .finish(reason: .stop)], deltaDelay: delay)
		let events = try await collect(transport.stream(request("Slowly")))
		#expect(textDeltas(in: events) == ["one", "two"])
		#expect(events.count == 3)
		#expect(clock.slept == [delay, delay, delay])
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

}

private func request(_ content: String) -> CompletionRequest {
	testRequest(
		[WireMessage(role: .user, content: content, toolCalls: [], toolCallId: nil)],
		deadline: .seconds(30))
}
