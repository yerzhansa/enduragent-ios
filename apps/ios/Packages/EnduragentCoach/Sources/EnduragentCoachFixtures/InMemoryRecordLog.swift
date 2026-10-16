import EnduragentCoach
import Foundation
import Synchronization

package final class InMemoryRecordLog: RecordLog, @unchecked Sendable {
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

	package var imports: AsyncStream<Void> {
		AsyncStream { _ in }
	}
}
