import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushGateTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func softFlushNeedsFiveMessagesAndEightyPercent() {
		#expect(
			FlushGate.shouldQueueSoftFlush(
				estimatedHistoryTokens: 81, historyBudget: 100, messagesSinceLastFlush: 5))
		#expect(
			!FlushGate.shouldQueueSoftFlush(
				estimatedHistoryTokens: 80, historyBudget: 100, messagesSinceLastFlush: 5))
		#expect(
			!FlushGate.shouldQueueSoftFlush(
				estimatedHistoryTokens: 90, historyBudget: 100, messagesSinceLastFlush: 4))
	}

	@Test func messagesSinceFlushComeFromTheLog() async throws {
		let history = try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		let at = clock.now.addingTimeInterval(-5)
		let job = FlushJobID(ulid: ULID.generate(at: at))
		try await seed(
			store,
			[
				seededRecord(
					store, at: at, ulid: job.ulid,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, trigger: .softThreshold,
								messageUlids: history.prefix(2).flatMap { [$0.user, $0.reply] },
								process: ProcessID(ulid: fixedUlid(60)))))),
				seededRecord(
					store, at: at.addingTimeInterval(1),
					ulid: ULID.generate(at: at.addingTimeInterval(1)),
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(chatId: .main, job: job, settlement: .nothingToSave)))),
			])
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let synced = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: .main))
		let conversation = ConversationFold.fold(
			chat: .main, synced: synced.records, device: store.deviceId)
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(
			conversation.messagesSinceLastFlush(jobs, excluding: nil).map(\.ulid) == [
				history[2].user, history[2].reply,
			])

		transport.script = [.text("Noted."), .finish(reason: .stop)]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("And Sunday?")
		#expect(transport.requests.map(\.charge) == [.chatAttempt])
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending]))).records.count
				== 1)
	}

	@Test func retryingAStoppedPartialDoesNotCountItsOwnMessagesTowardSoftFlush() async throws {
		try await seedHistory(
			store, clock: clock, turns: 2, tokens: historyBudget(clock: clock) * 9 / 10)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		transport.script = [.text("Superseded partial"), .hang]
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		await coach.stop(.main)
		let stopped = try #require(await coach.settledState(of: turn, in: .main))
		try #require(stopped.retryable)
		guard case .interrupted(let interrupted) = stopped else {
			Issue.record("Expected a stopped reply")
			return
		}
		try #require(interrupted.partial == "Superseded partial")
		transport.script = [.text("Replacement reply"), .finish(reason: .stop)]
		try await coach.retry(turn, in: .main)
		#expect(
			replyText(try #require(await coach.settledState(of: turn, in: .main)))
				== "Replacement reply")
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending])))
				.records.isEmpty)
	}

	@Test func aRetriedQuestionBeforeASavedWindowIsStillUnsaved() async throws {
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		transport.script = [.fail(.http(status: 400))]
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		let failed = try #require(await coach.settledState(of: turn, in: .main))
		try #require(failed.retryable)
		let longReply = String(repeating: "w", count: historyBudget(clock: clock) * 3)
		transport.script = [
			.text("First."), .finish(reason: .stop),
			.text("Second."), .finish(reason: .stop),
			.text(longReply), .finish(reason: .stop),
			.text("Ready."), .finish(reason: .stop),
		]
		for question in ["First question", "Second question", "Plan the week", "Anything else?"] {
			_ = try await coach.sendAndSettle(question)
		}
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		let saved = try #require(jobs.first)
		let user = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.userMessage]), turn: turn))
				.records.first?.ulid)
		try #require(jobs.count == 1)
		try #require(saved.saved)
		let newest = try #require(saved.messages.max())
		try #require(user < newest)
		#expect(!saved.messages.contains(user))
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		try await coach.retry(turn, in: .main)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == "Noted.")
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let window = try #require(sent(.memoryFlush, by: transport).last).messages.map(
			\.unstampedContent)
		#expect(window.filter { $0 == "Remember Saturdays" }.count == 1)
		#expect(window.filter { $0 == "Noted." }.count == 1)
		#expect(!window.contains("First question"))
		let reset = try #require(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).last)
		#expect(reset.messages.contains(user))
	}
}
