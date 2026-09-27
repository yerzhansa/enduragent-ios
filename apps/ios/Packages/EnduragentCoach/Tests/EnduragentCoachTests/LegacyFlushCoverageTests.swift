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
								chatId: .main, trigger: .softThreshold,
								messageUlids: [question, reply])))),
				record(job.ulid.incremented(), logical: 4, body: consumed(job)),
			])
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		transport.script = [.text("Fresh modern reply"), .finish(reason: .stop)]
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
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(\.content)
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
								chatId: .main, trigger: .softThreshold,
								messageUlids: [fixedUlid(4), fixedUlid(6)])))),
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
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main).count == 4)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(\.content)
		#expect(extracted.filter { $0 == "Imported modern question" }.count == 1)
		#expect(extracted.filter { $0 == "Imported modern reply" }.count == 1)
	}

	@Test func aListedLegacyTurnKeptAcrossResetIsNotExtractedAgain() async throws {
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
								chatId: .main, trigger: .softThreshold,
								messageUlids: [question, reply])))),
				record(job.ulid.incremented(), logical: 4, body: consumed(job)),
			])
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		try #require(await coach.transcript(.main) == ["Legacy question", "Legacy reply"])
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let conversation = try await ledger.conversation(.main)
		let boundary = try #require(conversation.current.id.boundary)
		try #require(job.ulid < boundary)
		try #require(boundary < question)
		try #require(await coach.transcript(.main) == ["Legacy question", "Legacy reply"])
		try #require(sent(.memoryFlush, by: transport).isEmpty)
		clock.advance(by: 120)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let extracted = sent(.memoryFlush, by: transport).flatMap(\.messages).map(\.content)
		#expect(!extracted.contains("Legacy question"))
		#expect(!extracted.contains("Legacy reply"))
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
