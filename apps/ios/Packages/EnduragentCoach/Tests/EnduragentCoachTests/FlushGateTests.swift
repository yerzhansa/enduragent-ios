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
								messageUlids: history.prefix(2).flatMap { [$0.user, $0.reply] })))),
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
		let jobs = try await ledger.flushJobs(in: .main)
		#expect(
			conversation.current.messagesSinceLastFlush(jobs, excluding: nil).map(\.ulid) == [
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
}
