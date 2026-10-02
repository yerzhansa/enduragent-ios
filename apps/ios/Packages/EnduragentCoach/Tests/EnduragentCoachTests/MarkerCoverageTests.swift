import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct MarkerCoverageTests {
	@Test(arguments: [false, true], [false, true])
	func aPartialNewerSettlementDoesNotHideAV1ConsumedMarker(hasMarker: Bool, allChats: Bool)
		async throws
	{
		let store = BatchRecordingLog(inner: InMemoryRecordLog())
		let device = store.deviceId
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let older = FlushJobID(ulid: fixedUlid(6))
		let newer = FlushJobID(ulid: fixedUlid(9))
		var records = [1, 4, 7].flatMap { first in
			[
				storedRecord(
					device: device, wall: Int64(first), ulid: fixedUlid(first),
					body: legacyUser(chatId: .main, text: "Question \(first)")),
				storedRecord(
					device: device, wall: Int64(first + 1), ulid: fixedUlid(first + 1),
					body: legacyReply(chatId: .main, text: "Reply \(first)")),
			]
		}
		let local: [(Int, DeviceLocalRecordBody)] = [
			(6, .flushPending(FlushPendingBody(chatId: .main, messageUlids: []))),
			(
				9,
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [4, 5, 7, 8].map(fixedUlid),
						process: ProcessID(ulid: fixedUlid(60))))
			),
			(
				10,
				.flushSettled(
					FlushSettledBody(chatId: .main, job: newer, settlement: .nothingToSave))
			),
		]
		records += local.map { offset, body in
			storedRecord(
				device: device, wall: Int64(offset), ulid: fixedUlid(offset),
				body: .deviceLocal(body))
		}
		if hasMarker {
			records.append(
				storedRecord(
					device: device, wall: 11, ulid: fixedUlid(11),
					body: .synced(
						.provenance(
							ProvenanceBody(
								key: MemoryFlushPolicy.consumedFlushKeyPrefix + older.ulid.rawValue,
								garmin: false, nonGarmin: false, unknown: false,
								contentSha256: "consumed")))))
		}
		try await seed(store, records)
		let conversation = try await ledger.conversation(.main)
		let localRecords = try await ledger.read(
			RecordQuery(scope: ConversationFold.flushScope, writtenBy: device)
		).records
		let before = store.reads.count
		let jobs =
			if allChats {
				try await ledger.flushJobsByChat(in: [.main: conversation], local: localRecords)[
					.main] ?? []
			} else {
				try await ledger.flushJobs(in: conversation)
			}
		#expect(
			Array(store.reads.dropFirst(before))
				== (allChats ? [] : [ConversationFold.flushScope]) + [
					ConversationFold.consumedMarkerScope
				])
		let legacy = try #require(jobs.first { $0.id == older })
		#expect(legacy.phase == (hasMarker ? .settled(.consumedBeforeUpgrade) : .pending))
		#expect(
			FlushJob.outstanding(jobs, in: conversation).map(\.id) == (hasMarker ? [] : [older]))
	}
}
