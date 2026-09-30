import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushCoverageRound2Tests {
	let device = DeviceID(rawValue: "phone-a")

	@Test func aNewerV1EmptyListSupersedesAnOlderJobThroughResolvedRows() {
		let conversation = legacyConversation(turns: 3)
		let older = job(6, messages: [1, 2, 4, 5])
		let newer = job(9, messages: [])

		#expect(newer.process == nil)
		#expect(newer.messages.isEmpty)
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
		var newer = job(9, messages: [7, 8])
		newer.settled = newerSettled
		let jobs = [older, newer]
		let resolved = FlushRows(jobs, in: conversation)
		let settled = FlushJob.settling(jobs, resolved: resolved.byJob)
		#expect(!settled[0].settled)
		#expect(conversation.flushRows(for: older).map(\.ulid) == [1, 2, 4, 5].map(fixedUlid))
		#expect(
			FlushJob.outstanding(settled, in: conversation).map(\.id)
				== (newerSettled ? [older.id] : [older.id, newer.id]))
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

	private func job(_ offset: Int, messages: [Int]) -> FlushJob {
		FlushJob(
			id: FlushJobID(ulid: fixedUlid(offset)),
			messages: messages.map(fixedUlid),
			process: messages.isEmpty ? nil : ProcessID(ulid: fixedUlid(60)), settled: false)
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
