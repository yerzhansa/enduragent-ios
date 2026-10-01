import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushCoverageRound2Tests {
	let device = DeviceID(rawValue: "phone-a")

	@Test func aNewerV1EmptyListSupersedesAnOlderJobThroughResolvedRows() {
		let conversation = legacyConversation(turns: 3)
		let older = job(6, messages: [1, 2, 4, 5])
		let newer = job(9, messages: [])

		#expect(newer.origin == .beforeUpgrade)
		#expect(newer.coverage.listed.isEmpty)
		#expect(
			conversation.flushRows(for: newer).map(\.ulid)
				== [1, 2, 4, 5, 7, 8].map(fixedUlid))
		#expect(
			FlushJob.outstanding([older, newer], in: conversation).map(\.id) == [newer.id])
	}

	@Test(arguments: [false, true])
	func anOlderV1EmptyListKeepsRowsMissingFromANewerJob(newerSettled: Bool) {
		let conversation = legacyConversation(turns: 3)
		let older = job(6, messages: [])
		let newer = job(9, messages: [7, 8], settled: newerSettled)
		let jobs = [older, newer]
		#expect(older.phase == .pending)
		#expect(!newer.covers(older))
		#expect(conversation.flushRows(for: older).map(\.ulid) == [1, 2, 4, 5].map(fixedUlid))
		#expect(
			FlushJob.outstanding(jobs, in: conversation).map(\.id)
				== (newerSettled ? [older.id] : [older.id, newer.id]))
	}

	@Test func aLegacyJobWithNoMessagesCoversItsSegmentBeforeIt() throws {
		let archived = TurnID(ulid: fixedUlid(1))
		let current = TurnID(ulid: fixedUlid(5))
		let records = [
			storedRecord(
				device: device, wall: 1, ulid: fixedUlid(1),
				body: .synced(sampleUser(chatId: .main, text: "archived", turn: archived))),
			storedRecord(
				device: device, wall: 2, ulid: fixedUlid(2),
				body: .synced(sampleReply(chatId: .main, turn: archived, text: "archived reply"))),
			storedRecord(
				device: device, wall: 4, ulid: fixedUlid(4),
				body: .synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: fixedUlid(4),
							reason: .reset(ResetID(ulid: fixedUlid(4))))))),
			storedRecord(
				device: device, wall: 5, ulid: fixedUlid(5),
				body: .synced(sampleUser(chatId: .main, text: "new", turn: current))),
			storedRecord(
				device: device, wall: 6, ulid: fixedUlid(6),
				body: .synced(sampleReply(chatId: .main, turn: current, text: "new reply"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: device)
		let legacy = FlushJob(
			id: FlushJobID(ulid: fixedUlid(3)), origin: .beforeUpgrade,
			coverage: ConversationRows(conversation).coverage(
				for: FlushJobID(ulid: fixedUlid(3)), messages: [], origin: .beforeUpgrade),
			reset: nil)
		#expect(
			conversation.flushMessages(for: legacy).map(\.text) == ["archived", "archived reply"])
		#expect(
			conversation.messagesSinceLastFlush([legacy], excluding: nil).map(\.ulid) == [
				fixedUlid(5), fixedUlid(6),
			])
	}

	private func legacyConversation(turns count: Int, startingAt: Int = 1) -> Conversation {
		let records = (0..<count).flatMap { index in
			let first = index * 3 + startingAt
			return [
				storedRecord(
					device: device, wall: Int64(first), ulid: fixedUlid(first),
					body: legacyUser(chatId: .main, text: "Question \(index)")),
				storedRecord(
					device: device, wall: Int64(first + 1), ulid: fixedUlid(first + 1),
					body: legacyReply(chatId: .main, text: "Reply \(index)")),
			]
		}
		return ConversationFold.fold(chat: .main, synced: records, device: device)
	}

	private func job(_ offset: Int, messages: [Int], settled: Bool = false) -> FlushJob {
		let id = FlushJobID(ulid: fixedUlid(offset))
		let origin: FlushJob.Origin =
			messages.isEmpty ? .beforeUpgrade : .process(ProcessID(ulid: fixedUlid(60)))
		return
			FlushJob(
				id: id, origin: origin,
				coverage: ConversationRows(legacyConversation(turns: 3)).coverage(
					for: id, messages: messages.map(fixedUlid), origin: origin),
				phase: settled ? .settled(.recorded(.nothingToSave)) : .pending, reset: nil)
	}
}

extension ExecutionLeaseTests {
	@Test func allSettledFlushJobsStartNoRecoveryLeaseOrDrainWrites() async throws {
		let turn = try #require(
			try await seedHistory(store, clock: clock, turns: 1, tokens: 200).first)
		let openedAt = clock.now.addingTimeInterval(-5)
		let job = FlushJobID(ulid: ULID.generate(at: openedAt))
		try await seed(
			store,
			[
				seededRecord(
					store, at: openedAt, ulid: job.ulid,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [turn.user, turn.reply],
								process: ProcessID(ulid: fixedUlid(60)))))),
				seededRecord(
					store, at: openedAt.addingTimeInterval(1),
					ulid: ULID.generate(at: openedAt.addingTimeInterval(1)),
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(
								chatId: .main, job: job, settlement: .nothingToSave)))),
			])

		let recording = BatchRecordingLog(inner: store)
		let recoveryHost = ImmediateExecutionHost()
		let relaunched = await makeCoach(
			transport: transport, store: recording, clock: clock, host: recoveryHost)
		await relaunched.lifecycle(.becameActive)
		await relaunched.lifecycle(.willTerminate)

		#expect(recoveryHost.leases.isEmpty)
		#expect(recording.batches == [["providerConsent"]])
		#expect(sent(.memoryFlush, by: transport).isEmpty)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending]))).records.count
				== 1)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records.count
				== 1)
	}
}
