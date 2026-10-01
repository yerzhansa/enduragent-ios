import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct LedgerCursorRecoveryTests {
		let device = DeviceID(rawValue: "phone-a")
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test(arguments: [false, true])
		func preLedgerRowsCannotDuplicateULIDsWhenTheClockIsBehind(tiedClocks: Bool) async throws {
			let fixture = try fixture()
			let head = try row(wall: 900_000_000_000, ulid: fixedUlid(30))
			let collision = try row(
				wall: tiedClocks ? head.hlcWallMs : head.hlcWallMs - 1, ulid: fixedUlid(31))
			let highest = try row(wall: collision.hlcWallMs, ulid: fixedUlid(50))
			for row in [head, collision, highest] {
				row.envelopeVersion = 1
				row.bodyVersion = 1
				row.body = Data(
					#"{"userMessage":{"_0":{"chatId":"main","athleteText":"before Ledger"}}}"#.utf8)
				fixture.context.insert(row)
			}
			try fixture.context.save()
			let before = try await fixture.log.fetch(RecordQuery(scope: .everySynced))
			try #require(before.records.count == 3)
			#expect(before.skipped.isEmpty)
			let ledger = Ledger(
				log: fixture.log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let written = try await ledger.commit(
				synced: [sampleUser(chatId: .main, text: "after upgrade")], stamp: testStamp())
			let next = try #require(written.first)
			#expect(next.ulid == fixedUlid(51))
			#expect(next.hlc.wallMs == head.hlcWallMs)
			#expect(next.hlc.logical == 1)
			let records = try await ledger.read(RecordQuery(scope: .everySynced)).records
			#expect(records.count == 4)
			#expect(Set(records.map(\.ulid)).count == records.count)
		}

		@Test(arguments: [false, true])
		func malformedHeadsDoNotBlockReadsOrCommits(allMalformed: Bool) async throws {
			let fixture = try fixture()
			if !allMalformed {
				fixture.context.insert(try row(wall: 900_000_000_000, ulid: fixedUlid(10)))
			}
			let first = try row(wall: 900_000_000_002, ulid: fixedUlid(12))
			first.ulid = "invalid-head"
			let second = try row(wall: 900_000_000_001, ulid: fixedUlid(11))
			second.ulid = "invalid-second"
			fixture.context.insert(first)
			fixture.context.insert(second)
			try fixture.context.save()
			let diagnostics = DiagnosticsLog(clock: clock)
			let ledger = Ledger(log: fixture.log, clock: clock, diagnostics: diagnostics)
			_ = try await ledger.read(RecordQuery(scope: .synced([.languagePreference])))
			let expected = [first, second].map {
				DiagnosticsEvent.skippedRecord(.malformed(kind: $0.kind, ulid: $0.ulid))
			}
			#expect(diagnostics.entries.map(\.event) == expected)
			let written = try await ledger.commit(
				synced: [sampleUser(chatId: .main, text: "still writable")], stamp: testStamp())
			let next = try #require(written.first)
			if !allMalformed {
				#expect(next.hlc.wallMs == 900_000_000_000)
				#expect(next.hlc.logical == 1)
				#expect(next.ulid == fixedUlid(11))
			}
			let page = try await ledger.read(RecordQuery(scope: .everySynced))
			#expect(page.records.contains(next))
			#expect(page.skipped.count == 2)
			#expect(diagnostics.entries.map(\.event) == expected)
		}

		@Test(arguments: [Int64(-1), Int64(UInt32.max) + 1])
		func malformedClockIsSkippedButItsULIDRemainsReserved(logical: Int64) async throws {
			let fixture = try fixture()
			fixture.context.insert(try row(wall: 900_000_000_000, ulid: fixedUlid(10)))
			let malformed = try row(wall: 900_000_000_001, ulid: fixedUlid(11))
			malformed.hlcLogical = logical
			fixture.context.insert(malformed)
			try fixture.context.save()
			let diagnostics = DiagnosticsLog(clock: clock)
			let ledger = Ledger(log: fixture.log, clock: clock, diagnostics: diagnostics)
			let written = try await ledger.commit(
				synced: [sampleUser(chatId: .main, text: "after malformed clock")],
				stamp: testStamp())
			let next = try #require(written.first)
			#expect(next.ulid == fixedUlid(12))
			#expect(next.hlc.wallMs == 900_000_000_000)
			#expect(next.hlc.logical == 1)
			let expected = DiagnosticsEvent.skippedRecord(
				.malformed(kind: malformed.kind, ulid: malformed.ulid))
			#expect(diagnostics.entries.map(\.event) == [expected])
			let page = try await ledger.read(RecordQuery(scope: .everySynced))
			#expect(page.records.count == 2)
			#expect(page.skipped.count == 1)
			#expect(diagnostics.entries.map(\.event) == [expected])
		}

		private func row(wall: Int64, ulid: ULID) throws -> StoredAthleteRecord {
			try StoredAthleteRecord(
				record: storedRecord(
					device: device, wall: wall, ulid: ulid,
					body: .synced(sampleUser(chatId: .main, text: "stored"))))
		}

		private func fixture() throws -> (log: SwiftDataRecordLog, context: ModelContext) {
			let root = FileManager.default.temporaryDirectory.appending(
				path: "enduragent-cursor-recovery-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let synced = try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "synced.store"))
			let local = try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "local.store"))
			let context = ModelContext(synced.container)
			context.autosaveEnabled = false
			return (SwiftDataRecordLog(deviceId: device, synced: synced, local: local), context)
		}
	}
}
