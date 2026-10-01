import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct TranscriptReadTests {
	@Test func aRetryClaimHidesTheOldReplyFromHistoryAndPendingRows() async throws {
		let inner = InMemoryRecordLog()
		let store = BatchRecordingLog(inner: inner)
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let turn = TurnID(ulid: fixedUlid(1))
		let bodies: [(Int, RecordBody)] = [
			(1, .synced(sampleUser(chatId: .main, text: "Question", turn: turn))),
			(2, .synced(sampleReply(chatId: .main, turn: turn, text: "Old reply"))),
			(
				3,
				.deviceLocal(
					.turnClaim(
						TurnClaimBody(
							chatId: .main, turn: turn, attempt: AttemptID(ulid: fixedUlid(3)),
							process: ProcessID(ulid: fixedUlid(60)), lease: .continuedProcessing)))
			),
			(
				4,
				.deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, messageUlids: [fixedUlid(1), fixedUlid(2)],
							process: ProcessID(ulid: fixedUlid(60)))))
			),
		]
		try await seed(
			inner,
			bodies.map { offset, body in
				storedRecord(
					device: inner.deviceId, wall: Int64(offset), ulid: fixedUlid(offset), body: body
				)
			})
		let conversation = try await ledger.conversation(.main)
		let jobs = try await ledger.flushJobs(in: conversation)
		let transcript = Transcript(
			conversation: conversation, jobs: jobs, excluding: TurnID(ulid: fixedUlid(90)))
		#expect(transcript.history.messages.isEmpty)
		#expect(transcript.unflushed.isEmpty)
		#expect(transcript.pending.map(\.ulid) == [fixedUlid(1)])
		#expect(transcript.pending.map(\.message.text) == ["Question"])
		#expect(transcript.flushPending)
		#expect(store.reads.filter { $0 == ConversationFold.syncedScope }.count == 1)
		#expect(store.reads.filter { $0 == ConversationFold.localScope }.count == 1)
	}
}
