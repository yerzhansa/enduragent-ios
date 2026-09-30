import Foundation
import SQLite3
import SwiftData
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
			let record = storedRecord(
				device: device, wall: 900_000_000_000, logical: 7, ulid: fixedUlid(1),
				body: .synced(sampleUser(chatId: .main, text: "before indexes")))
			try autoreleasepool {
				try writeWithoutIndexes(record, to: url)
			}
			let expected: Set<String> = ["ZDEVICEID,ZHLCWALLMS,ZHLCLOGICAL", "ZKIND,ZCHATID"]
			#expect(try indexColumns(at: url).isDisjoint(with: expected))
			let log = SwiftDataRecordLog(
				deviceId: device,
				synced: try ModelContainerHandle.withoutCloudKit(storeURL: url),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")))
			#expect(try await log.fetch(RecordQuery(scope: .everySynced)).records == [record])
			#expect(try expected.isSubset(of: indexColumns(at: url)))
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let written = try await ledger.commit(
				synced: [sampleUser(chatId: .main, text: "after indexes")], stamp: testStamp())
			#expect(written.first?.hlc.logical == 8)
			#expect(
				try await log.fetch(RecordQuery(scope: .everySynced)).records == [record] + written)
		}

		private func writeWithoutIndexes(_ record: AthleteRecord, to url: URL) throws {
			let schema = Schema([UnindexedRecordSchema.StoredAthleteRecord.self])
			let configuration = ModelConfiguration(
				schema: schema, url: url, cloudKitDatabase: .none)
			let container = try ModelContainer(for: schema, configurations: [configuration])
			let context = ModelContext(container)
			context.autosaveEnabled = false
			context.insert(try UnindexedRecordSchema.StoredAthleteRecord(record: record))
			try context.save()
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

private enum UnindexedRecordSchema {
	@Model
	final class StoredAthleteRecord {
		var envelopeVersion: Int = 1
		var ulid: String = ""
		var deviceId: String = ""
		var hlcWallMs: Int64 = 0
		var hlcLogical: Int64 = 0
		var hlcDeviceId: String = ""
		var timeZone: String = ""
		var civilDate: String = ""
		var kind: String = ""
		var bodyVersion: Int = 1
		var chatId: String?
		var turn: String?
		var operation: String?
		var attempt: String?
		var account: String?
		var body: Data = Data()

		static let currentEnvelopeVersion = 2

		init(record: AthleteRecord) throws {
			let encoded = try RecordCodec.encode(record.body)
			self.envelopeVersion = Self.currentEnvelopeVersion
			self.ulid = record.ulid.rawValue
			self.deviceId = record.deviceId.rawValue
			self.hlcWallMs = record.hlc.wallMs
			self.hlcLogical = Int64(record.hlc.logical)
			self.hlcDeviceId = record.hlc.deviceId.rawValue
			self.timeZone = record.timeZone.identifier
			self.civilDate = record.civilDate.rawValue
			self.kind = record.body.kind
			self.bodyVersion = encoded.version
			self.chatId = record.body.chatId?.rawValue
			self.turn = record.body.turn?.ulid.rawValue
			switch record.cause {
			case .operation(let operation, let attempt):
				self.operation = operation.storedValue
				self.attempt = attempt.ulid.rawValue
			case .legacy:
				self.operation = nil
				self.attempt = nil
			}
			self.account = record.account.storedValue
			self.body = encoded.data
		}

	}
}
