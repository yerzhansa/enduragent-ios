import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordCursorTests {
		let device = DeviceID(rawValue: "phone-a")
		let remote = DeviceID(rawValue: "phone-b")
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test(arguments: RecordLogKind.allCases)
		func latestFiltersDeviceAndStoreThenSortsBothClockComponents(kind: RecordLogKind)
			async throws
		{
			let log = try makeRecordLog(kind, deviceId: device)
			#expect(try await log.latest(locality: .synced, writtenBy: device) == nil)
			#expect(try await log.latest(locality: .deviceLocal, writtenBy: device) == nil)
			let local = storedRecord(
				device: device, wall: 900_000_000_000, logical: 3, ulid: fixedUlid(3),
				body: .deviceLocal(.flushPending(FlushPendingBody(chatId: .main, messageUlids: [])))
			)
			let synced = storedRecord(
				device: device, wall: local.hlc.wallMs, logical: 5, ulid: fixedUlid(4),
				body: .synced(sampleUser(chatId: .main, text: "latest local message")))
			try await seed(
				log,
				[
					synced, local,
					storedRecord(
						device: remote, wall: local.hlc.wallMs + 1, ulid: fixedUlid(99),
						body: .synced(sampleUser(chatId: .main, text: "remote message"))),
					storedRecord(
						device: device, wall: local.hlc.wallMs - 1, logical: 20, ulid: fixedUlid(1),
						body: .synced(sampleUser(chatId: .main, text: "older wall time"))),
					storedRecord(
						device: device, wall: local.hlc.wallMs, logical: 2, ulid: fixedUlid(2),
						body: .synced(sampleUser(chatId: .main, text: "older logical time"))),
				])
			#expect(
				try await log.latest(locality: .synced, writtenBy: device)
					== RecordCursor(ulid: synced.ulid, hlc: synced.hlc))
			#expect(
				try await log.latest(locality: .deviceLocal, writtenBy: device)
					== RecordCursor(ulid: local.ulid, hlc: local.hlc))
			let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let written = try await ledger.commit(
				local: [.flushPending(FlushPendingBody(chatId: .main, messageUlids: []))],
				stamp: testStamp())
			let next = try #require(written.first)
			#expect(next.hlc.wallMs == synced.hlc.wallMs)
			#expect(next.hlc.logical == synced.hlc.logical + 1)
			#expect(next.ulid > synced.ulid)
		}

		@Test func openUsesEnvelopeWithoutDecodingTheBody() async throws {
			let schema = Schema([StoredAthleteRecord.self])
			let container = try ModelContainer(
				for: schema,
				configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
			let stored = storedRecord(
				device: device, wall: 900_000_000_000, logical: 7, ulid: fixedUlid(1),
				body: .synced(sampleUser(chatId: .main, text: "unreadable body")))
			let row = try StoredAthleteRecord(record: stored)
			row.body = Data("unreadable".utf8)
			let context = ModelContext(container)
			context.insert(row)
			try context.save()
			let handle = ModelContainerHandle(container: container)
			let log = SwiftDataRecordLog(deviceId: device, synced: handle, local: handle)
			let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let written = try await ledger.commit(
				synced: [sampleUser(chatId: .main, text: "after reopening")], stamp: testStamp())
			let next = try #require(written.first)
			#expect(next.hlc.wallMs == stored.hlc.wallMs)
			#expect(next.hlc.logical == stored.hlc.logical + 1)
			#expect(next.ulid > stored.ulid)
		}

		@Test(arguments: RecordLogKind.allCases, [RecordLocality.synced, .deviceLocal])
		func openUsesIndependentClockAndULIDMaxima(kind: RecordLogKind, locality: RecordLocality)
			async throws
		{
			let log = try makeRecordLog(kind, deviceId: device)
			let body: RecordBody =
				locality == .synced
				? .synced(sampleUser(chatId: .main, text: "stored"))
				: .deviceLocal(.flushPending(FlushPendingBody(chatId: .main, messageUlids: [])))
			try await seed(
				log,
				[
					storedRecord(
						device: device, wall: 900_000_000_000, ulid: fixedUlid(1), body: body),
					storedRecord(
						device: device, wall: 899_000_000_000, ulid: fixedUlid(2), body: body),
					storedRecord(
						device: DeviceID(rawValue: "phone-b"), wall: 901_000_000_000,
						ulid: fixedUlid(99), body: body),
				])
			let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let written = try await ledger.commit(
				synced: [sampleUser(chatId: .main, text: "new")], stamp: testStamp())
			#expect(written.first?.ulid == fixedUlid(3))
			#expect(written.first?.hlc.wallMs == 900_000_000_000)
			#expect(written.first?.hlc.logical == 1)
		}
	}
}
