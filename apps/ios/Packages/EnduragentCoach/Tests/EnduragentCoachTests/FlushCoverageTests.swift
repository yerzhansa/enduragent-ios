import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushCoverageTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func anOlderImportedTurnIsSavedAfterANewerLocalTurnWasFlushed() async throws {
		let local = try #require(
			try await seedHistory(store, clock: clock, turns: 1, tokens: 200).first)
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
								messageUlids: [local.user, local.reply])))),
				seededRecord(
					store, at: at.addingTimeInterval(1), ulid: job.ulid.incremented(),
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(
								chatId: .main, job: job, settlement: .saved(sections: 1, events: 0))
						))),
			])
		let asked = clock.now.addingTimeInterval(-120)
		let question = ULID.generate(at: asked)
		let reply = ULID.generate(at: asked.addingTimeInterval(1))
		let turn = TurnID(ulid: question)
		let foreign = DeviceID(rawValue: "other-phone")
		try await seed(
			store,
			[
				storedRecord(
					device: foreign, wall: Int64(asked.timeIntervalSince1970 * 1_000),
					ulid: question,
					body: .synced(sampleUser(chatId: .main, text: "Remember Saturdays", turn: turn))
				),
				storedRecord(
					device: foreign, wall: Int64(asked.timeIntervalSince1970 * 1_000) + 1_000,
					ulid: reply,
					body: .synced(
						sampleReply(chatId: .main, turn: turn, text: "Noted on my other phone."))),
			])
		transport.flushScript = [
			.toolCall(
				name: "memory_write",
				arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#),
			.finish(reason: .toolCalls), .finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let flushed = try #require(sent(.memoryFlush, by: transport).first).messages.map(\.content)
		#expect(flushed.contains("Remember Saturdays"))
		#expect(flushed.contains("Noted on my other phone."))
		#expect(!flushed.contains("Question 0"))
		#expect(!flushed.contains { $0.hasPrefix("Answer 0") })
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let fresh = try #require(try await ledger.flushJobs(in: .main).last)
		#expect(fresh.messages == [question, reply])
		#expect(try await coach.memory.fullContext().contains("Group ride on Saturdays."))
	}

	@Test func aLegacyEmptyListStillCoversEarlierRowsInItsCurrentSegment() {
		let conversation = conversation(turns: 3)
		let legacy = job(6, messages: [], settled: true)
		#expect(
			conversation.flushRows(for: legacy).map(\.ulid) == [1, 2, 4, 5].map(fixedUlid))
		#expect(
			conversation.messagesSinceLastFlush([legacy], excluding: nil).map(\.ulid)
				== [7, 8].map(fixedUlid))
	}

	@Test func coverageIncludesSavedAbandonedOutstandingAndSupersededJobs() {
		let conversation = conversation(turns: 5)
		var abandoned = job(21, messages: [4, 5], settled: true)
		abandoned.abandoned = true
		let jobs = [
			job(20, messages: [1, 2], settled: true), abandoned,
			job(22, messages: [7], settled: false), job(23, messages: [7, 8], settled: false),
			job(24, messages: [10, 11], settled: true),
		]
		#expect(!abandoned.saved)
		#expect(FlushJob.outstanding(jobs).map(\.id) == [jobs[3].id])
		#expect(conversation.outstandingRows(jobs).map(\.ulid) == [7, 8].map(fixedUlid))
		#expect(
			conversation.messagesSinceLastFlush(jobs, excluding: nil).map(\.ulid)
				== [13, 14].map(fixedUlid))
	}

	@Test func coverageKeepsPromptTrimmingAndRunningTurnExclusion() {
		var conversation = conversation(turns: 3)
		conversation.segments[0].promptWindow.firstIncluded = fixedUlid(4)
		let running = TurnID(ulid: fixedUlid(7))
		#expect(
			conversation.messagesSinceLastFlush([], excluding: running).map(\.ulid)
				== [4, 5].map(fixedUlid))
		let pending = job(20, messages: [1, 2], settled: false)
		#expect(conversation.outstandingRows([pending]).map(\.ulid) == [1, 2].map(fixedUlid))
	}

	private func conversation(turns count: Int) -> Conversation {
		let records = (0..<count).flatMap { index in
			let first = index * 3 + 1
			let turn = TurnID(ulid: fixedUlid(first))
			return [
				storedRecord(
					device: store.deviceId, wall: Int64(first), ulid: fixedUlid(first),
					body: .synced(sampleUser(chatId: .main, text: "Question \(index)", turn: turn))),
				storedRecord(
					device: store.deviceId, wall: Int64(first + 1), ulid: fixedUlid(first + 1),
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Reply \(index)"))),
			]
		}
		return ConversationFold.fold(chat: .main, synced: records, device: store.deviceId)
	}

	private func job(_ offset: Int, messages: [Int], settled: Bool) -> FlushJob {
		FlushJob(
			id: FlushJobID(ulid: fixedUlid(offset)), trigger: .softThreshold,
			messages: messages.map(fixedUlid), settled: settled)
	}
}
