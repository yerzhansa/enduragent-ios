import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ResetWindowTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let host = ImmediateExecutionHost()

	let schedule: ScriptedEvent = .toolCall(
		name: "memory_write",
		arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#)

	func coach(over log: (any RecordLog)? = nil, window: Duration = .milliseconds(20)) -> Coach {
		makeCoach(
			transport: transport, store: log ?? store, clock: clock,
			coalescing: CoalescingPolicy(window: window), host: host)
	}

	func flushed() -> [[String]] {
		sent(.memoryFlush, by: transport).map { $0.messages.map(\.content) }
	}

	@Test func aReplyStreamingAtTheTapIsSavedWithItsQuestion() async throws {
		transport.script = [.text("Two"), .text(" rides."), .finish(reason: .stop)]
		transport.deltaDelay = .milliseconds(300)
		let coach = coach()
		let turn = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let resetting = startNewConversation(on: coach)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let window = try #require(flushed().first)
		#expect(window.contains("How was my week?"))
		#expect(window.contains("Two rides."))
		let archived = try #require(try await coach.history().first)
		#expect(replyText(try #require(archived.turns.first?.state)) == "Two rides.")
	}

	@Test func aTurnStillInTheJoinWindowAtTheTapIsSavedWithItsReply() async throws {
		transport.script = [.text("Two rides."), .finish(reason: .stop)]
		transport.requestDelay = .milliseconds(400)
		let coach = coach(window: .seconds(1))
		_ = try #require(try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		let resetting = startNewConversation(on: coach)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let window = try #require(flushed().first)
		#expect(window.contains("How was my week?"))
		#expect(window.contains("Two rides."))
	}

	@Test func aSendAheadInTheDoorBelongsToTheArchivedConversation() async throws {
		let held = HeldAppendLog(inner: store, holding: "userMessage", occurrence: 2)
		let coach = coach(over: held)
		transport.script = [.text("Two rides."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("How was my week?")
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		let sending = Task { try await coach.send(draft("Remember Saturdays"), to: .main) }
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		let resetting = startNewConversation(on: coach)
		try await Task.sleep(for: .milliseconds(200))
		held.release()
		_ = try await sending.value
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let archived = try #require(try await coach.history().first)
		#expect(archived.turns.compactMap { replyText($0.state) } == ["Two rides.", "Noted."])
		#expect(await coach.transcript(.main).isEmpty)
		let window = try #require(flushed().first)
		#expect(window.contains("Remember Saturdays"))
		#expect(window.contains("Noted."))
	}

	@Test func rowsAnOlderSavedJobCoveredAreNotSavedAgain() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 2, tokens: 400)
		let pendingAt = clock.now.addingTimeInterval(-6)
		let job = ULID.generate(at: pendingAt)
		try await seed(
			store,
			[
				seededRecord(
					store, at: pendingAt, ulid: job,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, trigger: .softThreshold,
								messageUlids: [history[0].user, history[0].reply],
								process: ProcessID(ulid: fixedUlid(80)))))),
				seededRecord(
					store, at: clock.now.addingTimeInterval(-5),
					ulid: ULID.generate(at: clock.now.addingTimeInterval(-5)),
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(
								chatId: .main, job: FlushJobID(ulid: job),
								settlement: .saved(sections: 1, events: 0))))),
			])
		transport.flushScript = [schedule, .finish(reason: .toolCalls)]
		#expect(await coach().startNewConversation(in: .main) == .started(memory: .saved))
		let window = try #require(flushed().first)
		#expect(!window.contains("Question 0"))
		#expect(window.contains("Question 1"))
	}
}
