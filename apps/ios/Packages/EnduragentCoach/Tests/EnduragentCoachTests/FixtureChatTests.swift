import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FixtureChatTests {
	@Test func queuedRequestsKeepTheirOwnReplies() async throws {
		let transport = FakeModelTransport { text, _ in
			ScriptedReply(
				[.text("Reply to " + text), .finish(reason: .stop)],
				requestDelay: text == "Hold" ? .seconds(1) : nil)
		}
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog())
		let held = try #require(try await coach.send(draft("Hold"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(held)
		let deadline = ContinuousClock.now + .seconds(5)
		while transport.requestCount == 0, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(transport.requestCount == 1)
		let first = try #require(try await coach.send(draft("Thursday"), to: .main).acceptedTurn)
		try await Task.sleep(for: .milliseconds(40))
		let second = try #require(try await coach.send(draft("Saturday"), to: .main).acceptedTurn)
		let firstReply = try #require(await coach.settledState(of: first, in: .main))
		let secondReply = try #require(await coach.settledState(of: second, in: .main))
		#expect(replyText(firstReply) == "Reply to Thursday")
		#expect(replyText(secondReply) == "Reply to Saturday")
	}
	@Test func retryRecoversButANewIdenticalMessageKeepsItsFailure() async throws {
		let transport = FakeModelTransport { _, retry in
			ScriptedReply(
				retry ? [.text("Recovered"), .finish(reason: .stop)] : [.fail(.http(status: 401))])
		}
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog())
		let turn = try #require(try await coach.send(draft("Fail"), to: .main).acceptedTurn)
		let first = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(first) == nil)
		try await coach.retry(turn, in: .main)
		let retried = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(retried) == "Recovered")
		#expect(replyText(try await coach.sendAndSettle("Fail")) == nil)
		#expect(transport.requestCount == 3)
	}

	@Test func aNewConversationStartsTheSameDirectiveAgain() async throws {
		let transport = FakeModelTransport { _, retry in
			ScriptedReply(
				retry ? [.text("Recovered"), .finish(reason: .stop)] : [.fail(.http(status: 401))])
		}
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog())
		#expect(replyText(try await coach.sendAndSettle("Fail")) == nil)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(replyText(try await coach.sendAndSettle("Fail")) == nil)
	}

	@Test func aHangingScriptKeepsHangingAcrossAutomaticRetries() async throws {
		let transport = FakeModelTransport { _, _ in ScriptedReply([.hang]) }
		let request = testRequest([
			WireMessage(role: .system, content: "Test", toolCalls: [], toolCallId: nil),
			WireMessage(role: .user, content: "Hang", toolCalls: [], toolCallId: nil),
		])
		for _ in 0..<2 {
			let reading = Task {
				for try await _ in transport.stream(request) {}
				return Task.isCancelled
			}
			try await Task.sleep(for: .milliseconds(50))
			reading.cancel()
			#expect(try await reading.value)
		}
	}

}
