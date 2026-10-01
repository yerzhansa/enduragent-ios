import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LegacyFlushCoverageTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let store = InMemoryRecordLog()
	let transport = FakeModelTransport()

	@Test func aFreshModernTurnBelowAForeignLegacyReceiptIsExtracted() async throws {
		let foreign = DeviceID(rawValue: "legacy-other-phone")
		let question = ULID.generate(at: clock.now.addingTimeInterval(60))
		let reply = question.incremented()
		let job = FlushJobID(ulid: ULID.generate(at: clock.now.addingTimeInterval(-60)))
		try await seed(
			store,
			[
				record(
					question, logical: 1, device: foreign,
					body: legacyUser(chatId: .main, text: "Legacy question")),
				record(
					reply, logical: 2, device: foreign,
					body: legacyReply(chatId: .main, text: "Legacy reply")),
				record(
					job.ulid, logical: 3,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [question, reply])))),
				record(job.ulid.incremented(), logical: 4, body: consumed(job)),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		transport.respond = ScriptedReply.sequence(
			[.text("Fresh modern reply"), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let turn = try #require(
			try await coach.send(draft("Fresh modern question"), to: .main).acceptedTurn)
		try #require(
			replyText(try #require(await coach.settledState(of: turn, in: .main)))
				== "Fresh modern reply")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let conversation = try await ledger.conversation(.main)
		let fresh = try #require(conversation.turn(turn))
		try #require(try #require(fresh.userRow?.ulid) > job.ulid)
		try #require(try #require(fresh.replyRow?.ulid) < reply)
		try #require(sent(.memoryFlush, by: transport).isEmpty)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(
			\.unstampedContent)
		#expect(extracted.filter { $0 == "Fresh modern question" }.count == 1)
		#expect(extracted.filter { $0 == "Fresh modern reply" }.count == 1)
		#expect(!extracted.contains("Legacy question"))
	}

	@Test(arguments: [false, true])
	func anImportedModernTurnOutsideALegacyListIsExtracted(consumedInV1: Bool) async throws {
		let job = FlushJobID(ulid: fixedUlid(7))
		try await seed(
			store,
			[
				record(
					fixedUlid(4), logical: 1,
					body: legacyUser(chatId: .main, text: "Legacy question")),
				record(
					fixedUlid(6), logical: 2, body: legacyReply(chatId: .main, text: "Legacy reply")
				),
				record(
					job.ulid, logical: 3,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [fixedUlid(4), fixedUlid(6)])))),
			])
		if consumedInV1 {
			try await seed(store, [record(fixedUlid(8), logical: 4, body: consumed(job))])
		}
		let turn = TurnID(ulid: fixedUlid(1))
		let foreign = DeviceID(rawValue: "modern-other-phone")
		try await seed(
			store,
			[
				record(
					fixedUlid(1), logical: 5, device: foreign,
					body: .synced(
						sampleUser(chatId: .main, text: "Imported modern question", turn: turn))),
				record(
					fixedUlid(2), logical: 6, device: foreign,
					body: .synced(
						sampleReply(chatId: .main, turn: turn, text: "Imported modern reply"))),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == 4)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(
			\.unstampedContent)
		#expect(extracted.filter { $0 == "Imported modern question" }.count == 1)
		#expect(extracted.filter { $0 == "Imported modern reply" }.count == 1)
	}

	@Test func aListedLegacyTurnArchivedByObservedResetIsNotExtractedAgain() async throws {
		let foreign = DeviceID(rawValue: "legacy-other-phone")
		let question = ULID.generate(at: clock.now.addingTimeInterval(60))
		let reply = question.incremented()
		let job = FlushJobID(ulid: ULID.generate(at: clock.now.addingTimeInterval(-60)))
		try await seed(
			store,
			[
				record(
					question, logical: 1, device: foreign,
					body: legacyUser(chatId: .main, text: "Legacy question")),
				record(
					reply, logical: 2, device: foreign,
					body: legacyReply(chatId: .main, text: "Legacy reply")),
				record(
					job.ulid, logical: 3,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [question, reply])))),
				record(job.ulid.incremented(), logical: 4, body: consumed(job)),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main) == ["Legacy question", "Legacy reply"])
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let conversation = try await ledger.conversation(.main)
		let boundary = try #require(conversation.current.id.boundary)
		try #require(job.ulid < boundary)
		try #require(boundary < question)
		#expect(await coach.transcript(.main).isEmpty)
		let archivedRef = try #require(try await coach.history().first?.id)
		let archived = try #require(try await coach.archivedConversation(archivedRef))
		#expect(archived.turns.map(\.athleteText) == ["Legacy question"])
		#expect(replyText(try #require(archived.turns.first?.state)) == "Legacy reply")
		try #require(sent(.memoryFlush, by: transport).isEmpty)
		let reopened = await makeCoach(transport: transport, store: store, clock: clock)
		#expect(await reopened.transcript(.main).isEmpty)
		#expect(try await reopened.archivedConversation(archivedRef) == archived)
		clock.advance(by: 120)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(
			\.unstampedContent)
		#expect(!extracted.contains("Legacy question"))
		#expect(!extracted.contains("Legacy reply"))
	}

	@Test(arguments: [false, true])
	func twoLegacyReceiptsCoverMergedRowsThroughTheNewestCutoff(emptyLatestList: Bool) async throws
	{
		let records = (0..<3).flatMap { index in
			let first = index * 3 + 1
			return [
				record(
					fixedUlid(first), logical: UInt32(first),
					body: legacyUser(chatId: .main, text: "Saved question \(index)")),
				record(
					fixedUlid(first + 1), logical: UInt32(first + 1),
					body: legacyReply(chatId: .main, text: "Saved reply \(index)")),
			]
		}
		try await seed(store, records)
		for (id, messages) in [(3, [1, 2]), (9, emptyLatestList ? [] : [7, 8])] {
			let job = FlushJobID(ulid: fixedUlid(id))
			try await seed(
				store,
				[
					record(
						job.ulid, logical: UInt32(id),
						body: .deviceLocal(
							.flushPending(
								FlushPendingBody(
									chatId: .main, messageUlids: messages.map(fixedUlid))))),
					record(fixedUlid(id + 10), logical: UInt32(id + 10), body: consumed(job)),
				])
		}
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == 6)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(sent(.memoryFlush, by: transport).isEmpty)
	}

	@Test func aModernEmptyReceiptDoesNotCoverUnlistedLegacyRows() async throws {
		let job = FlushJobID(ulid: fixedUlid(7))
		try await seed(
			store,
			[
				record(
					fixedUlid(1), logical: 1,
					body: legacyUser(chatId: .main, text: "Unsaved legacy question")),
				record(
					fixedUlid(2), logical: 2,
					body: legacyReply(chatId: .main, text: "Unsaved legacy reply")),
				record(
					job.ulid, logical: 3,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [],
								process: ProcessID(ulid: fixedUlid(60)))))),
				record(
					fixedUlid(8), logical: 4,
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(chatId: .main, job: job, settlement: .nothingToSave)))),
			])
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(
			\.unstampedContent)
		#expect(extracted.filter { $0 == "Unsaved legacy question" }.count == 1)
		#expect(extracted.filter { $0 == "Unsaved legacy reply" }.count == 1)
	}

	@Test(arguments: [false, true])
	func aModernReplyToALegacyQuestionIsNotInferredCovered(incremental: Bool) {
		let question = record(
			fixedUlid(1), logical: 1,
			body: legacyUser(chatId: .main, text: "Legacy question"))
		let reply = record(
			fixedUlid(2), logical: 2,
			body: .synced(
				sampleReply(
					chatId: .main, turn: TurnID(ulid: question.ulid),
					text: "Modern reply")))
		let conversation: Conversation
		if incremental {
			var initial = ConversationFold.fold(
				chat: .main, synced: [question], device: store.deviceId)
			initial.apply([reply], device: store.deviceId)
			conversation = initial
		} else {
			conversation = ConversationFold.fold(
				chat: .main, synced: [question, reply], device: store.deviceId)
		}
		let legacy = FlushJob(
			id: FlushJobID(ulid: fixedUlid(7)), origin: .beforeUpgrade,
			coverage: ConversationRows(conversation).coverage(
				for: FlushJobID(ulid: fixedUlid(7)), messages: [fixedUlid(4), fixedUlid(6)],
				origin: .beforeUpgrade, consumed: true),
			phase: .settled(.consumedBeforeUpgrade), reset: nil)
		#expect(
			conversation.messagesSinceLastFlush([legacy], excluding: nil).map(\.ulid) == [
				reply.ulid
			])
	}

	@Test(arguments: [false, true])
	func anEmptyReceiptDoesNotCoverModernRows(legacyReceipt: Bool) {
		let question = record(
			fixedUlid(1), logical: 1,
			body: .synced(
				sampleUser(chatId: .main, text: "Modern question", turn: TurnID(ulid: fixedUlid(1)))
			))
		let reply = record(
			fixedUlid(2), logical: 2,
			body: .synced(
				sampleReply(chatId: .main, turn: TurnID(ulid: question.ulid), text: "Modern reply"))
		)
		let conversation = ConversationFold.fold(
			chat: .main, synced: [question, reply], device: store.deviceId)
		let origin: FlushJob.Origin =
			legacyReceipt ? .beforeUpgrade : .process(ProcessID(ulid: fixedUlid(60)))
		let receipt = FlushJob(
			id: FlushJobID(ulid: fixedUlid(7)), origin: origin,
			coverage: ConversationRows(conversation).coverage(
				for: FlushJobID(ulid: fixedUlid(7)), messages: [], origin: origin),
			phase: .settled(.recorded(.nothingToSave)), reset: nil)
		#expect(
			conversation.messagesSinceLastFlush([receipt], excluding: nil).map(\.ulid) == [
				question.ulid, reply.ulid,
			])
	}

	private func consumed(_ job: FlushJobID) -> RecordBody {
		.synced(
			.provenance(
				ProvenanceBody(
					key: MemoryFlushPolicy.consumedFlushKeyPrefix + job.ulid.rawValue,
					garmin: false, nonGarmin: false, unknown: false, contentSha256: "consumed")))
	}

	private func record(_ ulid: ULID, logical: UInt32, device: DeviceID? = nil, body: RecordBody)
		-> AthleteRecord
	{
		storedRecord(
			device: device ?? store.deviceId, wall: 899_164_800_000, logical: logical, ulid: ulid,
			body: body)
	}
}
