import Testing

@testable import EnduragentCoach

@Suite struct FlushJobReadTests {
	@Test(arguments: [false, true], [false, true])
	func provenanceIsReadOnlyForLocallyUnsettledJobs(allChats: Bool, unsettled: Bool) async throws {
		let store = BatchRecordingLog(inner: InMemoryRecordLog())
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, trigger: .softThreshold, messageUlids: [fixedUlid(1)],
						process: ProcessID(ulid: fixedUlid(60))))
			], stamp: testStamp())
		let job = FlushJobID(ulid: try #require(records.first?.ulid))
		_ = try await ledger.commit(
			local: [
				.flushSettled(FlushSettledBody(chatId: .main, job: job, settlement: .nothingToSave))
			], stamp: testStamp())
		if unsettled {
			let legacy = try await ledger.commit(
				local: [
					.flushPending(
						FlushPendingBody(
							chatId: .main, trigger: .trim, messageUlids: [fixedUlid(2)]))
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
		let before = store.reads.count
		let jobs =
			if allChats {
				try await ledger.flushJobsByChat()[.main] ?? []
			} else {
				try await ledger.flushJobs(in: .main)
			}
		#expect(jobs.count == (unsettled ? 2 : 1))
		#expect(jobs.allSatisfy { $0.saved })
		#expect(
			Array(store.reads.dropFirst(before))
				== (unsettled
					? [ConversationFold.flushScope, ConversationFold.consumedMarkerScope]
					: [ConversationFold.flushScope]))
	}
}
