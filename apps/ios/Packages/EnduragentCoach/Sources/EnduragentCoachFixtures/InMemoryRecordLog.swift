import EnduragentCoach
import Foundation
import Synchronization

package final class InMemoryRecordLog: ReviewChainLog, @unchecked Sendable {
	package let deviceId: DeviceID
	private let records = Mutex<[AthleteRecord]>([])

	package init(deviceId: DeviceID = DeviceID()) {
		self.deviceId = deviceId
	}

	package func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		records.withLock { $0.append(contentsOf: batch) }
	}

	package func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let matching = records.withLock { $0.filter { recordMatches($0, query) } }
		return RecordPage(records: matching.sorted { $0.hlc < $1.hlc }, skipped: [])
	}

	package func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor?
	{
		records.withLock { records in
			let matching = records.lazy.filter {
				$0.locality == locality && $0.deviceId == writtenBy
			}
			guard let hlc = matching.map(\.hlc).max() else { return nil }
			return RecordCursor(ulid: matching.map(\.ulid).max(), hlc: hlc)
		}
	}

	package func newest(_ query: RecordQuery) async throws -> NewestRecord {
		NewestRecord(records.withLock { Self.newest(query, in: $0) })
	}

	package func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
	{
		try records.withLock { records in
			let current = NewestRecord(Self.newest(query, in: records)).head
			guard current == head else { throw HeadMoved(current: current) }
			records.append(record)
		}
	}

	package func chats(holding scope: RecordQuery.Scope) async throws -> Set<ChatID> {
		let query = RecordQuery(scope: scope)
		return records.withLock { records in
			Set(records.filter { recordMatches($0, query) }.compactMap(\.chatId))
		}
	}

	private static func newest(_ query: RecordQuery, in records: [AthleteRecord]) -> AthleteRecord?
	{
		records.filter { recordMatches($0, query) }.max { $0.hlc < $1.hlc }
	}

	package func erase(_ locality: RecordLocality, sparing kept: DeviceID?) async throws -> Int {
		records.withLock { records in
			let before = records.count
			records.removeAll { $0.locality == locality && $0.deviceId != kept }
			return before - records.count
		}
	}

	package func confirmSyncedExport(after saved: Date) async throws -> Bool { true }

	package var imports: AsyncStream<Void> {
		AsyncStream { _ in }
	}
}
