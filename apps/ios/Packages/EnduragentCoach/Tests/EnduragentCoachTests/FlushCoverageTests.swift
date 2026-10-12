import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct FlushCoverageTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func aQuestionQueuedBehindAListedReplyIsSavedOnce() async throws {
		try await seedHistory(
			store, clock: clock, turns: 2, tokens: historyBudget(clock: clock) * 85 / 100)
		transport.respond = ScriptedReply.sequence(
			[
				.text("Two"), .text(" rides."), .finish(reason: .stop),
				.text("Noted."), .finish(reason: .stop),
			], deltaDelay: .milliseconds(200), otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		let first = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(first)
		let queued = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		try #require(queued != first)
		_ = try #require(await coach.settledState(of: queued, in: .main))
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let soft = try #require(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).first)
		let question = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.userMessage]), turn: queued))
				.records.first?.ulid)
		try #require(!soft.coverage.listed.contains(question))
		try #require(question < (soft.coverage.listed.max() ?? question))
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let reset = try #require(sent(.memoryFlush, by: transport).last).messages.map(
			\.unstampedContent)
		#expect(reset.filter { $0 == "Remember Saturdays" }.count == 1)
		#expect(reset.filter { $0 == "Noted." }.count == 1)
		#expect(!reset.contains("How was my week?"))
	}

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
								chatId: .main, messageUlids: [local.user, local.reply],
								process: ProcessID(ulid: fixedUlid(60)))))),
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
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "memory_write",
					arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#),
				.finish(reason: .toolCalls), .finish(reason: .stop),
			], for: .flush, otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let flushed = try #require(sent(.memoryFlush, by: transport).first).messages.map(
			\.unstampedContent)
		#expect(flushed.contains("Remember Saturdays"))
		#expect(flushed.contains("Noted on my other phone."))
		#expect(!flushed.contains("Question 0"))
		#expect(!flushed.contains { $0.hasPrefix("Answer 0") })
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let fresh = try #require(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).last)
		#expect(fresh.coverage.listed == [question, reply])
		#expect(
			try await coach.memory.fullContext(for: testConnection.account).contains(
				"Group ride on Saturdays."))
	}

	@Test func v1ConsumedJobDoesNotReplayRowsMergedOutsideItsList() async throws {
		let job = FlushJobID(ulid: fixedUlid(7))
		try await seed(
			store,
			[
				record(4, wall: 1, body: legacyUser(chatId: .main, text: "Earlier question")),
				record(6, wall: 2, body: legacyReply(chatId: .main, text: "Earlier reply")),
				record(
					7, wall: 5,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [fixedUlid(4), fixedUlid(6)])))),
				record(
					1, wall: 1, device: DeviceID(rawValue: "other-phone"),
					body: legacyUser(chatId: .main, text: "Already saved Saturday")),
				record(
					2, wall: 2, device: DeviceID(rawValue: "other-phone"),
					body: legacyReply(chatId: .main, text: "Already saved reply")),
				record(
					8, wall: 6,
					body: .synced(
						consumedFlushMarker(for: job.ulid))),
			])
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		try #require(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).map(\.saved) == [
				true
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == 4)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let repeated = sent(.memoryFlush, by: transport).flatMap(\.messages).map(\.unstampedContent)
		#expect(!repeated.contains("Already saved Saturday"))
		#expect(!repeated.contains("Already saved reply"))
		#expect(sent(.memoryFlush, by: transport).isEmpty)
	}

	@Test func retryAfterItsPartialWasSavedExtractsOnlyTheReplacementReply() async throws {
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		transport.respond = ScriptedReply.sequence(
			[.text("Superseded partial"), .hang], otherwise: transport.respond)
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		await coach.stop(.main)
		try #require(
			turnNotice(of: try #require(await coach.settledState(of: turn, in: .main)))?.actions
				== [.tryAgain(turn)])
		let longReply = String(repeating: "w", count: historyBudget(clock: clock) * 3)
		transport.respond = ScriptedReply.sequence(
			[
				.text("First."), .finish(reason: .stop),
				.text("Second."), .finish(reason: .stop),
				.text(longReply), .finish(reason: .stop),
				.text("Ready."), .finish(reason: .stop),
			], otherwise: transport.respond)
		for question in ["First question", "Second question", "Plan the week", "Anything else?"] {
			_ = try await coach.sendAndSettle(question)
		}
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		let first = try #require(sent(.memoryFlush, by: transport).first)
		try #require(first.messages.contains { $0.unstampedContent == "Superseded partial" })
		try #require(first.messages.contains { $0.unstampedContent == "Remember Saturdays" })
		transport.respond = ScriptedReply.sequence(
			[.text("Replacement reply"), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		try await coach.retry(turn, in: .main)
		try #require(
			replyText(try #require(await coach.settledState(of: turn, in: .main)))
				== "Replacement reply")
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let latest = try #require(sent(.memoryFlush, by: transport).last).messages.map(
			\.unstampedContent)
		#expect(latest.filter { $0 == "Replacement reply" }.count == 1)
		#expect(!latest.contains("Superseded partial"))
		#expect(!latest.contains("Remember Saturdays"))
	}

	@Test func aTrimmedFailedQuestionBecomesEligibleWhenRetried() async throws {
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		transport.respond = ScriptedReply.sequence(
			[.fail(.http(status: 400))], otherwise: transport.respond)
		let turn = try #require(
			try await coach.send(draft("Recover after trimming"), to: .main).acceptedTurn)
		try #require(
			turnNotice(of: try #require(await coach.settledState(of: turn, in: .main)))?.actions
				== [.tryAgain(turn)])
		let huge = String(repeating: "w", count: historyBudget(clock: clock) * 5)
		transport.respond = ScriptedReply.sequence(
			[
				.text(huge), .finish(reason: .stop), .text("Ready"), .finish(reason: .stop),
			], otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier history"), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		_ = try await coach.sendAndSettle("Force a trim")
		_ = try await coach.sendAndSettle("After trimming")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let conversation = try await ledger.conversation(.main)
		try #require(conversation.current.promptWindows.values.first?.trim != nil)
		let user = try #require(conversation.turn(turn)?.userRow?.ulid)
		try #require(
			!conversation.current.promptHistory(
				excluding: nil, for: testConnection.account, device: store.deviceId,
				using: conversation.ownership
			).ulids.contains(user))
		transport.respond = ScriptedReply.sequence(
			[.text("Recovered reply"), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		try await coach.retry(turn, in: .main)
		try #require(
			replyText(try #require(await coach.settledState(of: turn, in: .main)))
				== "Recovered reply")
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let latest = try #require(sent(.memoryFlush, by: transport).last).messages.map(
			\.unstampedContent)
		#expect(latest.filter { $0 == "Recover after trimming" }.count == 1)
		#expect(latest.filter { $0 == "Recovered reply" }.count == 1)
		#expect(!latest.contains("Force a trim"))
		#expect(!latest.contains(huge))
	}

	@Test(arguments: [false, true])
	func aLegacyWatermarkDoesNotReachIntoTheNextConversation(legacyRows: Bool) async throws {
		let job = FlushJobID(ulid: fixedUlid(7))
		let foreign = DeviceID(rawValue: "other-phone")
		let turn = TurnID(ulid: fixedUlid(11))
		try await seed(
			store,
			[
				record(
					1, wall: 1, device: foreign,
					body: legacyUser(chatId: .main, text: "Archived question")),
				record(
					1_000, wall: 2, device: foreign,
					body: legacyReply(chatId: .main, text: "Archived late reply")),
				record(
					7,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [fixedUlid(1), fixedUlid(1_000)])))),
				record(
					8,
					body: .synced(
						consumedFlushMarker(for: job.ulid))),
				record(
					10,
					body: .synced(
						.windowStart(
							WindowStartBody(
								chatId: .main, firstIncludedUlid: fixedUlid(10),
								reason: .reset(ResetID(ulid: fixedUlid(10))))))),
				record(
					11,
					body: legacyRows
						? legacyUser(chatId: .main, text: "Current question")
						: .synced(sampleUser(chatId: .main, text: "Current question", turn: turn))),
				record(
					12,
					body: legacyRows
						? legacyReply(chatId: .main, text: "Current reply")
						: .synced(sampleReply(chatId: .main, turn: turn, text: "Current reply"))
				),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let rows = try #require(sent(.memoryFlush, by: transport).first).messages.map(
			\.unstampedContent)
		#expect(rows.filter { $0 == "Current question" }.count == 1)
		#expect(rows.filter { $0 == "Current reply" }.count == 1)
		#expect(!rows.contains("Archived question"))
		#expect(!rows.contains("Archived late reply"))
	}

	@Test func aLegacyEmptyListStillCoversEarlierRowsInItsCurrentSegment() {
		let conversation = conversation(turns: 3, legacy: true)
		let legacy = job(6, messages: [], settled: true, in: conversation)
		#expect(
			conversation.flushRows(for: legacy).map(\.ulid) == [1, 2, 4, 5].map(fixedUlid))
		#expect(
			conversation.messagesSinceLastFlush([legacy], excluding: nil).map(\.ulid)
				== [7, 8].map(fixedUlid))
	}

	@Test func coverageIncludesSavedAbandonedOutstandingAndSupersededJobs() {
		let conversation = conversation(turns: 5)
		let abandoned = FlushWork.transition(
			job(21, messages: [4, 5], settled: false, in: conversation),
			after: .settled(.recorded(.abandoned)))
		let jobs = [
			job(20, messages: [1, 2], settled: true, in: conversation), abandoned,
			job(22, messages: [7], settled: false, in: conversation),
			job(23, messages: [7, 8], settled: false, in: conversation),
			job(24, messages: [10, 11], settled: true, in: conversation),
		]
		#expect(!abandoned.saved)
		#expect(FlushJob.outstanding(jobs, in: conversation).map(\.id) == [jobs[3].id])
		#expect(conversation.outstandingRows(jobs).map(\.ulid) == [7, 8].map(fixedUlid))
		#expect(
			conversation.messagesSinceLastFlush(jobs, excluding: nil).map(\.ulid)
				== [13, 14].map(fixedUlid))
	}

	@Test func coverageKeepsPromptTrimmingAndRunningTurnExclusion() {
		var conversation = conversation(turns: 3)
		conversation.segments[0].promptWindows[.unbound(store.deviceId)] = PromptWindow(
			trim: .init(messageUlids: [fixedUlid(1), fixedUlid(2)], opened: fixedUlid(9)))
		let running = TurnID(ulid: fixedUlid(7))
		#expect(
			conversation.messagesSinceLastFlush([], excluding: running).map(\.ulid)
				== [4, 5].map(fixedUlid))
		let pending = job(20, messages: [1, 2], settled: false, in: conversation)
		#expect(conversation.outstandingRows([pending]).map(\.ulid) == [1, 2].map(fixedUlid))
	}

	private func conversation(turns count: Int, startingAt: Int = 1, legacy: Bool = false)
		-> Conversation
	{
		let records = (0..<count).flatMap { index in
			let first = index * 3 + startingAt
			let turn = TurnID(ulid: fixedUlid(first))
			return [
				storedRecord(
					device: store.deviceId, wall: Int64(first), ulid: fixedUlid(first),
					body: legacy
						? legacyUser(chatId: .main, text: "Question \(index)")
						: .synced(sampleUser(chatId: .main, text: "Question \(index)", turn: turn))),
				storedRecord(
					device: store.deviceId, wall: Int64(first + 1), ulid: fixedUlid(first + 1),
					body: legacy
						? legacyReply(chatId: .main, text: "Reply \(index)")
						: .synced(sampleReply(chatId: .main, turn: turn, text: "Reply \(index)"))),
			]
		}
		return ConversationFold.fold(chat: .main, synced: records, device: store.deviceId)
	}

	private func job(
		_ offset: Int, messages: [Int], settled: Bool, in conversation: Conversation
	) -> FlushJob {
		let id = FlushJobID(ulid: fixedUlid(offset))
		let origin: FlushJob.Origin =
			messages.isEmpty ? .beforeUpgrade : .process(ProcessID(ulid: fixedUlid(60)))
		return
			FlushJob(
				id: id, origin: origin,
				coverage: ConversationRows(conversation).coverage(
					for: id, messages: messages.map(fixedUlid), origin: origin),
				phase: settled ? .settled(.recorded(.nothingToSave)) : .pending, reset: nil)
	}

	private func record(
		_ offset: Int, wall: Int64? = nil, device: DeviceID? = nil, body: RecordBody
	) -> AthleteRecord {
		storedRecord(
			device: device ?? store.deviceId, wall: 899_164_800_000,
			logical: UInt32(wall ?? Int64(offset)), ulid: fixedUlid(offset), body: body)
	}
}
