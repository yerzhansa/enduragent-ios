import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct FlushJobReadTests {
	@Test(arguments: [false, true], [false, true])
	func provenanceIsReadOnlyWhenUnsettledV1JobsExist(allChats: Bool, hasUnsettledV1Jobs: Bool)
		async throws
	{
		let store = BatchRecordingLog(inner: InMemoryRecordLog())
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [fixedUlid(1)],
						process: ProcessID(ulid: fixedUlid(60))))
			], stamp: testStamp())
		let job = FlushJobID(ulid: try #require(records.first?.ulid))
		_ = try await ledger.commit(
			local: [
				.flushSettled(FlushSettledBody(chatId: .main, job: job, settlement: .nothingToSave))
			], stamp: testStamp())
		if hasUnsettledV1Jobs {
			let legacy = try await ledger.commit(
				local: [
					.flushPending(
						FlushPendingBody(
							chatId: .main, messageUlids: [fixedUlid(2)]))
				], stamp: testStamp())
			let legacyID = try #require(legacy.first?.ulid)
			_ = try await ledger.commit(
				synced: [
					.provenance(
						ProvenanceBody(
							key: MemoryFlushPolicy.consumedFlushKeyPrefix + legacyID.rawValue,
							garmin: false, nonGarmin: false, unknown: false,
							contentSha256: "consumed"))
				], stamp: testStamp())
		}
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
		#expect(jobs.count == (hasUnsettledV1Jobs ? 2 : 1))
		#expect(jobs.allSatisfy { $0.saved })
		#expect(
			Array(store.reads.dropFirst(before))
				== (hasUnsettledV1Jobs
					? (allChats ? [] : [ConversationFold.flushScope]) + [
						ConversationFold.consumedMarkerScope
					]
					: (allChats ? [] : [ConversationFold.flushScope])))
	}

	@Test(arguments: [false, true])
	func modernSettlementsOfV1JobsDoNotReadProvenance(allChats: Bool) async throws {
		let store = BatchRecordingLog(inner: InMemoryRecordLog())
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		for message in [fixedUlid(1), fixedUlid(2)] {
			let records = try await ledger.commit(
				local: [
					.flushPending(
						FlushPendingBody(
							chatId: .main, messageUlids: [message]))
				], stamp: testStamp())
			let job = FlushJobID(ulid: try #require(records.first?.ulid))
			_ = try await ledger.commit(
				local: [
					.flushSettled(
						FlushSettledBody(
							chatId: .main, job: job, settlement: .saved(sections: 1, events: 0)))
				], stamp: testStamp())
		}
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
		#expect(jobs.count == 2)
		#expect(jobs.allSatisfy { $0.process == nil && $0.saved && !$0.consumedInV1 })
		#expect(
			Array(store.reads.dropFirst(before)) == (allChats ? [] : [ConversationFold.flushScope]))
	}

	@Test(arguments: [false, true])
	func anEmptyConsumedV1JobReadsProvenanceAndSettles(allChats: Bool) async throws {
		let store = BatchRecordingLog(inner: InMemoryRecordLog())
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(chatId: .main, messageUlids: []))
			], stamp: testStamp())
		let id = try #require(records.first?.ulid)
		_ = try await ledger.commit(
			synced: [
				.provenance(
					ProvenanceBody(
						key: MemoryFlushPolicy.consumedFlushKeyPrefix + id.rawValue,
						garmin: false, nonGarmin: false, unknown: false,
						contentSha256: "consumed"))
			], stamp: testStamp())
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
		#expect(jobs.count == 1)
		#expect(jobs.allSatisfy { $0.saved })
		#expect(
			Array(store.reads.dropFirst(before))
				== (allChats ? [] : [ConversationFold.flushScope]) + [
					ConversationFold.consumedMarkerScope
				])
	}

	@Test(arguments: [false, true])
	func aPendingModernJobDoesNotReadProvenance(allChats: Bool) async throws {
		let store = BatchRecordingLog(inner: InMemoryRecordLog())
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		_ = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [fixedUlid(1)],
						process: ProcessID(ulid: fixedUlid(60))))
			], stamp: testStamp())
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
		#expect(jobs.count == 1)
		#expect(jobs.allSatisfy { !$0.settled })
		#expect(
			Array(store.reads.dropFirst(before))
				== (allChats ? [] : [ConversationFold.flushScope]))
	}

	@Test func aConsumedMarkerCannotSettleAModernJob() async throws {
		let store = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
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
		let modern = FlushJobID(ulid: try #require(records.first?.ulid))
		_ = try await ledger.commit(
			synced: [
				.provenance(
					ProvenanceBody(
						key: MemoryFlushPolicy.consumedFlushKeyPrefix + modern.ulid.rawValue,
						garmin: false, nonGarmin: false, unknown: false,
						contentSha256: "consumed"))
			], stamp: testStamp())
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(jobs.count == 2)
		#expect(jobs.allSatisfy { !$0.settled })
	}
}
