import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LedgerTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func twoWritersInOneMillisecondGetStrictlyIncreasingClocks() async throws {
		let log = InMemoryRecordLog(deviceId: phoneA)
		let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		async let synced = ledger.commit(
			synced: [
				sampleUser(chatId: .main, text: "one"), sampleUser(chatId: .main, text: "two"),
			],
			stamp: testStamp())
		async let local = ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(chatId: .main, trigger: .softThreshold, messageUlids: []))
			],
			stamp: testStamp())
		let written = try await synced + local
		let ordered = written.sorted { $0.hlc < $1.hlc }
		#expect(Set(ordered.map(\.hlc.wallMs)).count == 1)
		#expect(Set(ordered.map(\.hlc)).count == 3)
		#expect(Set(ordered.map(\.ulid)).count == 3)
		for index in 1..<ordered.count {
			#expect(ordered[index - 1].hlc < ordered[index].hlc)
			#expect(ordered[index - 1].ulid < ordered[index].ulid)
		}
	}

	@Test func readFoldsRemoteClocksIntoTheCursor() async throws {
		let log = InMemoryRecordLog(deviceId: phoneA)
		let remoteWall = Int64(clock.now.timeIntervalSince1970 * 1000) + 60_000
		try await seed(
			log,
			[
				storedRecord(
					device: phoneB, wall: remoteWall, logical: 4,
					body: .synced(sampleUser(chatId: .main, text: "from b")))
			]
		)
		let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		_ = try await ledger.read(RecordQuery(scope: .synced([.userMessage])))
		let written = try await ledger.commit(
			synced: [sampleUser(chatId: .main, text: "after b")], stamp: testStamp())
		let hlc = try #require(written.first?.hlc)
		#expect(hlc.wallMs == remoteWall)
		#expect(hlc.logical == 5)
		#expect(hlc.deviceId == phoneA)
	}

	@Test func openFoldsWhatThisDeviceWroteBefore() async throws {
		let log = InMemoryRecordLog(deviceId: phoneA)
		let earlierProcessWall = Int64(clock.now.timeIntervalSince1970 * 1000) + 5_000
		try await seed(
			log,
			[
				storedRecord(
					device: phoneA, wall: earlierProcessWall,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(chatId: .main, trigger: .trim, messageUlids: []))))
			]
		)
		let reopened = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let written = try await reopened.commit(
			synced: [sampleUser(chatId: .main, text: "later")], stamp: testStamp())
		#expect(written.first?.hlc.wallMs == earlierProcessWall)
		#expect(written.first?.hlc.logical == 1)
	}

	@Test func injectedAppendFailureStoresNothingFromTheBatch() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: phoneA))
		let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		log.failNextAppend = true
		await #expect(throws: LedgerFailure.rejectedBatch) {
			try await ledger.commit(
				synced: [
					sampleUser(chatId: .main, text: "one"), sampleUser(chatId: .main, text: "two"),
				],
				stamp: testStamp())
		}
		let stored = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(stored.isEmpty)
		let retried = try await ledger.commit(
			synced: [sampleUser(chatId: .main, text: "three")], stamp: testStamp())
		#expect(retried.count == 1)
	}

	@Test func nextULIDReservesABoundaryBeforeLaterWrites() async throws {
		let log = InMemoryRecordLog(deviceId: phoneA)
		let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let boundary = await ledger.nextULID()
		let written = try await ledger.commit(
			synced: [
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: boundary, reason: .reset(.daily))),
				sampleUser(chatId: .main, text: "first in the new segment"),
			],
			stamp: testStamp())
		for record in written {
			#expect(boundary < record.ulid)
		}
	}

	@Test func commitStampsZoneCivilDateCauseAndAccount() async throws {
		let log = InMemoryRecordLog(deviceId: phoneA)
		let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let tokyo = try #require(IANATimeZone(identifier: "Asia/Tokyo"))
		let stamp = testStamp(zone: tokyo)
		let written = try await ledger.commit(
			synced: [sampleUser(chatId: .main, text: "stamped")], stamp: stamp)
		let record = try #require(written.first)
		#expect(record.timeZone == tokyo)
		#expect(record.civilDate == "1998-06-13")
		#expect(record.cause == .operation(stamp.operation, stamp.attempt))
		#expect(record.account == .unconnected)
		#expect(record.deviceId == phoneA)
	}
}
