import Foundation
import SQLite3
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct IndexMigrationTests {
		@Test func storeWithoutIndexesReopensAndPreservesRecords() async throws {
			let root = FileManager.default.temporaryDirectory.appending(
				path: "enduragent-index-migration-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let url = root.appending(path: "synced.store")
			let device = DeviceID(rawValue: "phone-a")
			let fixture = try #require(
				Bundle.module.url(
					forResource: "unindexed-records", withExtension: "sql",
					subdirectory: "Fixtures"))
			let sql = try String(contentsOf: fixture, encoding: .utf8)
			try restoreRecordStore(sql, into: url)
			let expected: Set<String> = ["ZDEVICEID,ZHLCWALLMS,ZHLCLOGICAL", "ZKIND,ZCHATID"]
			#expect(try indexColumns(at: url).isDisjoint(with: expected))
			let log = SwiftDataRecordLog(
				deviceId: device,
				synced: try ModelContainerHandle.withoutCloudKit(storeURL: url),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")))
			let records = try await log.fetch(RecordQuery(scope: .everySynced)).records
			let record = try #require(records.first)
			#expect(records.count == 1)
			#expect(messageText(record) == "before indexes")
			#expect(record.ulid == fixedUlid(1))
			#expect(
				record.hlc
					== HybridLogicalClock(wallMs: 900_000_000_000, logical: 7, deviceId: device))
			#expect(try expected.isSubset(of: indexColumns(at: url)))
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let written = try await ledger.commit(
				synced: [sampleUser(chatId: .main, text: "after indexes")], stamp: testStamp())
			#expect(written.first?.hlc.logical == 8)
			#expect(
				try await log.fetch(RecordQuery(scope: .everySynced)).records == [record] + written)
		}

		private func indexColumns(at url: URL) throws -> Set<String> {
			var handle: OpaquePointer?
			try #require(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
			let database = try #require(handle)
			defer { sqlite3_close(database) }
			let sql = """
				SELECT group_concat(columnName, ',') FROM (
				    SELECT il.name AS indexName, ii.name AS columnName
				    FROM pragma_index_list('ZSTOREDATHLETERECORD') il
				    JOIN pragma_index_info(il.name) ii
				    ORDER BY il.name, ii.seqno
				) GROUP BY indexName
				"""
			var statement: OpaquePointer?
			try #require(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
			defer { sqlite3_finalize(statement) }
			var columns: Set<String> = []
			var result = sqlite3_step(statement)
			while result == SQLITE_ROW {
				let text = try #require(sqlite3_column_text(statement, 0))
				columns.insert(String(cString: text))
				result = sqlite3_step(statement)
			}
			try #require(result == SQLITE_DONE)
			return columns
		}
	}
}
