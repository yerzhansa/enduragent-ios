import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct FlushSettlementTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let store = InMemoryRecordLog()

	@Test func repeatedPendingRecordKeepsItsOutstandingRows() async throws {
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		let turn = try #require(history.first)
		let pending = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [turn.user, turn.reply],
						process: ProcessID(ulid: fixedUlid(60))))
			], stamp: testStamp())
		try await store.append(pending, locality: .deviceLocal)
		let conversation = try await ledger.conversation(.main)
		let jobs = try await ledger.flushJobs(in: conversation)
		#expect(Set(jobs.map(\.id)) == [FlushJobID(ulid: try #require(pending.first?.ulid))])
		#expect(jobs.allSatisfy { !$0.settled })
		#expect(conversation.outstandingRows(jobs).map(\.ulid) == [turn.user, turn.reply])
	}

	@Test(arguments: [false, true])
	func aConsumedNewerJobSettlesAnOlderCoveredJob(allChats: Bool) async throws {
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		let turn = try #require(history.first)
		let pending = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [turn.user],
						process: ProcessID(ulid: fixedUlid(60)))),
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [turn.user, turn.reply])),
			], stamp: testStamp())
		let older = FlushJobID(ulid: try #require(pending.first?.ulid))
		let newer = FlushJobID(ulid: try #require(pending.last?.ulid))
		_ = try await ledger.commit(
			synced: [
				.provenance(
					ProvenanceBody(
						key: MemoryFlushPolicy.consumedFlushKeyPrefix + newer.ulid.rawValue,
						garmin: false, nonGarmin: false, unknown: false,
						contentSha256: "consumed"))
			], stamp: testStamp())
		let conversation = try await ledger.conversation(.main)
		let jobs =
			if allChats {
				try await ledger.flushJobsByChat(in: [.main: conversation], local: pending)[.main]
					?? []
			} else {
				try await ledger.flushJobs(in: conversation)
			}
		#expect(jobs.map(\.id) == [older, newer])
		#expect(try #require(jobs.first { $0.id == older }).saved)
		#expect(try #require(jobs.first { $0.id == newer }).consumedInV1)
		#expect(FlushJob.outstanding(jobs, in: conversation).isEmpty)
	}

	@Test func refreshingJobsKeepsRowsAbsentFromANewerSettlement() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let ledger = Ledger(log: store, clock: clock, diagnostics: diagnostics)
		let history = try await seedHistory(store, clock: clock, turns: 2, tokens: 400)
		let first = try #require(history.first)
		let last = try #require(history.last)
		let pending = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [first.user, first.reply],
						process: ProcessID(ulid: fixedUlid(60)))),
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [last.user, last.reply],
						process: ProcessID(ulid: fixedUlid(60)))),
			], stamp: testStamp())
		let older = FlushJobID(ulid: try #require(pending.first?.ulid))
		let newer = FlushJobID(ulid: try #require(pending.last?.ulid))
		let records = ChatRecords(
			chat: .main, ledger: ledger, clock: clock,
			reviews: SingleProposalReviews(
				ledger: ledger, clock: clock, diagnostics: DiagnosticsLog(clock: clock),
				training: { .unconnected }))
		try await records.load()
		_ = try await ledger.commit(
			local: [
				.flushSettled(
					FlushSettledBody(chatId: .main, job: newer, settlement: .nothingToSave))
			], stamp: testStamp())
		let flushes = FlushWork(
			chat: .main, process: ProcessID(ulid: fixedUlid(61)), ledger: ledger,
			memory: Memory(ledger: ledger, clock: clock), transport: FakeModelTransport(),
			clock: clock, diagnostics: diagnostics)
		#expect(await records.refreshJobs(from: flushes) == [older])
		let outstanding = try #require(records.jobs.first { $0.id == older })
		#expect(!outstanding.settled)
		#expect(try #require(records.jobs.first { $0.id == newer }).saved)
		#expect(
			records.conversation.outstandingRows(records.jobs).map(\.ulid)
				== [first.user, first.reply])
	}
}
