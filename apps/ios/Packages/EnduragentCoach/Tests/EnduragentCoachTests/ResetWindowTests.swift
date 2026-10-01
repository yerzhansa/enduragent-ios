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

	func coach(over log: (any RecordLog)? = nil, window: Duration = .milliseconds(20)) async
		-> Coach
	{
		await makeCoach(
			transport: transport, store: log ?? store, clock: clock,
			coalescing: CoalescingPolicy(window: window), host: host)
	}

	func flushed() -> [[String]] {
		sent(.memoryFlush, by: transport).map { $0.messages.map(\.unstampedContent) }
	}

	@Test func aReplyStreamingAtTheTapIsSavedWithItsQuestion() async throws {
		transport.script = [.text("Two"), .text(" rides."), .finish(reason: .stop)]
		transport.deltaDelay = .milliseconds(300)
		let coach = await coach()
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
		let coach = await coach(window: .seconds(1))
		_ = try #require(try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		let resetting = startNewConversation(on: coach)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let window = try #require(flushed().first)
		#expect(window.contains("How was my week?"))
		#expect(window.contains("Two rides."))
	}

	@Test func aSendAheadInTheDoorBelongsToTheArchivedConversation() async throws {
		let held = HeldAppendLog(inner: store, holding: "userMessage", occurrence: 2)
		let coach = await coach(over: held)
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
								chatId: .main, messageUlids: [history[0].user, history[0].reply],
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

	@Test(arguments: [false, true])
	func aLateReplyMustNotCoverTheNextConversationsQuestion(relaunch: Bool) async throws {
		let (coach, user) = try await resetAcrossLateReply()
		let next =
			relaunch ? await makeCoach(transport: transport, store: store, clock: clock) : coach
		#expect(await next.startNewConversation(in: .main) == .started(memory: .saved))
		let requests = sent(.memoryFlush, by: transport)
		try #require(requests.count == 2)
		#expect(!requests[0].messages.contains { $0.unstampedContent == "Remember Saturdays" })
		#expect(
			requests[1].messages.filter { $0.unstampedContent == "Remember Saturdays" }.count == 1)
		#expect(requests[1].messages.filter { $0.unstampedContent == "Noted." }.count == 1)
		let jobs = try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending])))
			.records.sorted { $0.hlc < $1.hlc }.compactMap { record -> FlushPendingBody? in
				guard case .deviceLocal(.flushPending(let body)) = record.body else { return nil }
				return body
			}
		try #require(jobs.count == 2)
		#expect(!jobs[0].messageUlids.contains(user))
		#expect(jobs[1].messageUlids.filter { $0 == user }.count == 1)
		#expect(Set(jobs[1].messageUlids).count == jobs[1].messageUlids.count)
	}

	@Test func aSoftFlushAfterResetIncludesTheNextConversationsQuestion() async throws {
		let (coach, user) = try await resetAcrossLateReply()
		let reply = String(repeating: "w", count: historyBudget(clock: clock) * 3)
		transport.script = [
			.text("Noted again."), .finish(reason: .stop),
			.text(reply), .finish(reason: .stop),
			.text("Ready."), .finish(reason: .stop),
		]
		_ = try await coach.sendAndSettle("Remember Sundays too")
		_ = try await coach.sendAndSettle("Plan the week")
		_ = try await coach.sendAndSettle("Anything else?")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 2, in: store)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(jobs.count == 2)
		let job = try #require(jobs.last)
		#expect(job.coverage.listed.filter { $0 == user }.count == 1)
		let window = try #require(flushed().last)
		#expect(window.filter { $0 == "Remember Saturdays" }.count == 1)
		#expect(!window.contains("How was my week?"))
		#expect(!window.contains("Two rides."))
	}

	@Test func aSyncedTurnBeyondTheResetBoundaryStaysUnsavedInTheNewConversation() async throws {
		let foreign = InMemoryRecordLog(deviceId: DeviceID(rawValue: "phone-b"))
		let ahead = FixedClock(now: "1998-06-13T12:02:00+02:00", timeZone: "Europe/Amsterdam")
		let turns = try await seedHistory(foreign, clock: ahead, turns: 1, tokens: 40)
		try await seed(store, try await foreign.fetch(RecordQuery(scope: .everySynced)).records)
		let coach = await coach()
		let before = await coach.transcript(.main)
		try #require(before.count == 2)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let conversation = try await ledger.conversation(.main)
		let boundary = try #require(conversation.current.id.boundary)
		let first = try #require(turns.first)
		try #require(boundary < first.user)
		#expect(await coach.transcript(.main) == before)
		#expect(flushed().isEmpty)
		#expect(try await ledger.flushJobs(in: try await ledger.conversation(.main)).isEmpty)
	}

	private func resetAcrossLateReply() async throws -> (Coach, ULID) {
		let held = HeldAppendLog(inner: store, holding: "replyObserved", occurrence: 1)
		let coach = await coach(over: held)
		transport.script = [
			.text("Two rides."), .finish(reason: .stop),
			.text("Noted."), .finish(reason: .stop),
		]
		let first = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		let resetting = startNewConversation(on: coach)
		try await Task.sleep(for: .milliseconds(200))
		let second = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		held.release()
		#expect(try await outcome(resetting) == .started(memory: .saved))
		#expect(
			replyText(try #require(await coach.settledState(of: second, in: .main))) == "Noted.")
		let user = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.userMessage]), turn: second))
				.records.first?.ulid)
		let firstReply = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: first))
				.records.first?.ulid)
		let boundaries = try await store.fetch(RecordQuery(scope: .synced([.windowStart]))).records
			.compactMap { record -> WindowStartBody? in
				guard case .synced(.windowStart(let body)) = record.body else { return nil }
				return body
			}
		let opening = try #require(boundaries.first)
		try #require(opening.firstIncludedUlid < user)
		try #require(user < firstReply)
		#expect(await coach.transcript(.main) == ["Remember Saturdays", "Noted."])
		return (coach, user)
	}
}
