import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct FlushJobReadTests {
	let store = BatchRecordingLog(inner: InMemoryRecordLog())
	let ledger: Ledger

	init() {
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
	}

	@Test(arguments: [false, true], [false, true])
	func provenanceIsReadOnlyWhenUnsettledV1JobsExist(allChats: Bool, hasUnsettledV1Jobs: Bool)
		async throws
	{
		let job = FlushJobID(ulid: try await pending([1], modern: true))
		try await settle(job, .nothingToSave)
		if hasUnsettledV1Jobs {
			try await consume(try await pending([2], modern: false))
		}
		let (jobs, reads) = try await jobsAndReads(allChats: allChats)
		#expect(jobs.count == (hasUnsettledV1Jobs ? 2 : 1))
		#expect(jobs.allSatisfy { $0.saved })
		#expect(
			reads
				== (hasUnsettledV1Jobs
					? (allChats ? [] : [ConversationFold.flushScope]) + [
						ConversationFold.consumedMarkerScope
					]
					: (allChats ? [] : [ConversationFold.flushScope])))
	}

	@Test(arguments: [false, true])
	func modernSettlementsOfV1JobsDoNotReadProvenance(allChats: Bool) async throws {
		for message in [1, 2] {
			let job = FlushJobID(ulid: try await pending([message], modern: false))
			try await settle(job, .saved(sections: 1, events: 0))
		}
		let (jobs, reads) = try await jobsAndReads(allChats: allChats)
		#expect(jobs.count == 2)
		#expect(
			jobs.allSatisfy {
				$0.origin == .beforeUpgrade
					&& $0.phase == .settled(.recorded(.saved(sections: 1, events: 0)))
			})
		#expect(reads == (allChats ? [] : [ConversationFold.flushScope]))
	}

	@Test(arguments: [false, true])
	func anEmptyConsumedV1JobReadsProvenanceAndSettles(allChats: Bool) async throws {
		try await consume(try await pending([], modern: false))
		let (jobs, reads) = try await jobsAndReads(allChats: allChats)
		#expect(jobs.count == 1)
		#expect(jobs.allSatisfy { $0.saved })
		#expect(
			reads
				== (allChats ? [] : [ConversationFold.flushScope]) + [
					ConversationFold.consumedMarkerScope
				])
	}

	@Test(arguments: [false, true])
	func aPendingModernJobDoesNotReadProvenance(allChats: Bool) async throws {
		_ = try await pending([1], modern: true)
		let (jobs, reads) = try await jobsAndReads(allChats: allChats)
		#expect(jobs.count == 1)
		#expect(jobs.allSatisfy { $0.phase == .pending })
		#expect(reads == (allChats ? [] : [ConversationFold.flushScope]))
	}

	@Test func aConsumedMarkerCannotSettleAModernJob() async throws {
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [fixedUlid(1)],
						process: ProcessID(ulid: fixedUlid(60)))),
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [fixedUlid(2)])),
			], stamp: testStamp())
		try await consume(try #require(records.first?.ulid))
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(jobs.count == 2)
		#expect(jobs.allSatisfy { $0.phase == .pending })
	}

	private func pending(_ messages: [Int], modern: Bool) async throws -> ULID {
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: messages.map(fixedUlid),
						process: modern ? ProcessID(ulid: fixedUlid(60)) : nil))
			], stamp: testStamp())
		return try #require(records.first?.ulid)
	}

	private func settle(_ job: FlushJobID, _ settlement: FlushSettlement) async throws {
		_ = try await ledger.commit(
			local: [
				.flushSettled(FlushSettledBody(chatId: .main, job: job, settlement: settlement))
			],
			stamp: testStamp())
	}

	private func consume(_ job: ULID) async throws {
		_ = try await ledger.commit(synced: [consumedFlushMarker(for: job)], stamp: testStamp())
	}

	private func jobsAndReads(allChats: Bool) async throws
		-> (jobs: [FlushJob], reads: [RecordQuery.Scope])
	{
		let conversation = try await ledger.conversation(.main)
		let local = try await ledger.read(
			RecordQuery(scope: ConversationFold.flushScope, writtenBy: ledger.deviceId)
		).records
		let before = store.reads.count
		let jobs =
			if allChats {
				try await ledger.flushJobsByChat(in: [.main: conversation], local: local)[.main]
					?? []
			} else {
				try await ledger.flushJobs(in: conversation)
			}
		return (jobs, Array(store.reads.dropFirst(before)))
	}
}

func consumedFlushMarker(for job: ULID) -> SyncedRecordBody {
	.provenance(
		ProvenanceBody(
			key: MemoryFlushPolicy.consumedFlushKeyPrefix + job.rawValue,
			garmin: false, nonGarmin: false, unknown: false, contentSha256: "consumed"))
}
