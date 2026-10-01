import CoreData
import Foundation
import SwiftData
import Synchronization

package struct RecordQuery: Sendable, Equatable {
	package enum Scope: Sendable, Equatable {
		case synced(Set<SyncedKind>, includeLegacy: Set<LegacyKind>)
		case deviceLocal(Set<DeviceLocalKind>)

		package static func synced(_ kinds: Set<SyncedKind>) -> Scope {
			.synced(kinds, includeLegacy: [])
		}

		package static let everySynced: Scope = .synced(
			Set(SyncedKind.allCases), includeLegacy: Set(LegacyKind.allCases))
		package static let everyDeviceLocal: Scope = .deviceLocal(Set(DeviceLocalKind.allCases))

		var locality: RecordLocality {
			switch self {
			case .synced: .synced
			case .deviceLocal: .deviceLocal
			}
		}

		var isExhaustive: Bool {
			switch self {
			case .synced(let kinds, let legacy):
				kinds.count == SyncedKind.allCases.count
					&& legacy.count == LegacyKind.allCases.count
			case .deviceLocal(let kinds):
				kinds.count == DeviceLocalKind.allCases.count
			}
		}

		var kindNames: Set<String> {
			switch self {
			case .synced(let kinds, let legacy):
				Set(kinds.map(\.rawValue)).union(legacy.map(\.rawValue))
			case .deviceLocal(let kinds):
				Set(kinds.map(\.rawValue))
			}
		}

		func admits(_ body: RecordBody) -> Bool {
			switch (self, body) {
			case (.synced(let kinds, _), .synced(let synced)):
				kinds.contains(synced.kind)
			case (.synced(_, let legacy), .legacy(let body)):
				legacy.contains(body.kind)
			case (.deviceLocal(let kinds), .deviceLocal(let local)):
				kinds.contains(local.kind)
			default:
				false
			}
		}
	}

	package var scope: Scope
	package var chatId: ChatID?
	package var turn: TurnID?
	package var from: CivilDate?
	package var to: CivilDate?
	package var writtenBy: DeviceID?

	package init(
		scope: Scope,
		chatId: ChatID? = nil,
		turn: TurnID? = nil,
		from: CivilDate? = nil,
		to: CivilDate? = nil,
		writtenBy: DeviceID? = nil
	) {
		self.scope = scope
		self.chatId = chatId
		self.turn = turn
		self.from = from
		self.to = to
		self.writtenBy = writtenBy
	}
}

package protocol RecordLog: Sendable {
	var deviceId: DeviceID { get }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws
	func fetch(_ query: RecordQuery) async throws -> RecordPage
	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor?
	var imports: AsyncStream<Void> { get }
}

package struct RecordCursor: Sendable, Equatable {
	package let ulid: ULID?
	package let hlc: HybridLogicalClock?
	package var skipped: [SkippedRow] = []
}

package struct RecordPage: Sendable, Equatable {
	package let records: [AthleteRecord]
	package let skipped: [SkippedRow]

	package init(records: [AthleteRecord], skipped: [SkippedRow]) {
		self.records = records
		self.skipped = skipped
	}
}

package enum SkippedRow: Error, Sendable, Hashable {
	case newerKind(kind: String, ulid: String)
	case newerVersion(kind: String, version: Int, ulid: String)
	case malformed(kind: String, ulid: String)
}

package struct RecordDecodeFailure: Error, Sendable, Equatable {
	package var reason: String

	package init(reason: String) {
		self.reason = reason
	}
}

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

package struct SwiftDataRecordLog: RecordLog {
	package let deviceId: DeviceID
	private let synced: ModelContainer
	private let local: ModelContainer

	package init(deviceId: DeviceID, synced: ModelContainerHandle, local: ModelContainerHandle) {
		self.deviceId = deviceId
		self.synced = synced.container
		self.local = local.container
	}

	package func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let context = ModelContext(container(for: locality))
		context.autosaveEnabled = false
		for record in batch {
			context.insert(try StoredAthleteRecord(record: record))
		}
		try context.save()
	}

	package func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor?
	{
		let deviceId = writtenBy.rawValue
		let descriptor = FetchDescriptor<StoredAthleteRecord>(
			predicate: #Predicate { $0.deviceId == deviceId },
			sortBy: [
				SortDescriptor(\.hlcWallMs, order: .reverse),
				SortDescriptor(\.hlcLogical, order: .reverse),
			])
		let context = ModelContext(container(for: locality))
		var skipped: [SkippedRow] = []
		let hlc = try firstValue(in: context, matching: descriptor, skipped: &skipped) { row in
			ULID(rawValue: row.ulid) == nil ? nil : row.hlc
		}
		let ulidDescriptor = FetchDescriptor<StoredAthleteRecord>(
			predicate: #Predicate { $0.deviceId == deviceId },
			sortBy: [SortDescriptor(\.ulid, comparator: .lexical, order: .reverse)])
		let ulid = try firstValue(in: context, matching: ulidDescriptor, skipped: &skipped) {
			ULID(rawValue: $0.ulid)
		}
		guard hlc != nil || ulid != nil || !skipped.isEmpty else { return nil }
		return RecordCursor(ulid: ulid, hlc: hlc, skipped: skipped)
	}

	private func firstValue<Value>(
		in context: ModelContext, matching descriptor: FetchDescriptor<StoredAthleteRecord>,
		skipped: inout [SkippedRow], decode: (StoredAthleteRecord) -> Value?
	) throws -> Value? {
		var descriptor = descriptor
		descriptor.fetchLimit = 1
		while let row = try context.fetch(descriptor).first {
			if let value = decode(row) { return value }
			skipped.append(.malformed(kind: row.kind, ulid: row.ulid))
			descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + 1
		}
		return nil
	}

	package func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let kinds = query.scope.isExhaustive ? [] : Array(query.scope.kindNames)
		if kinds.isEmpty, !query.scope.isExhaustive {
			return RecordPage(records: [], skipped: [])
		}
		let anyKind = kinds.isEmpty
		let anyChat = query.chatId == nil
		let chatId = query.chatId?.rawValue ?? ""
		let anyTurn = query.turn == nil
		let turn = query.turn?.ulid.rawValue ?? ""
		let anyDevice = query.writtenBy == nil
		let deviceId = query.writtenBy?.rawValue ?? ""
		let predicate = #Predicate<StoredAthleteRecord> { row in
			(anyKind || kinds.contains(row.kind))
				&& (anyChat || row.chatId == chatId || row.chatId == nil)
				&& (anyTurn || row.turn == turn)
				&& (anyDevice || row.deviceId == deviceId)
		}
		let context = ModelContext(container(for: query.scope.locality))
		let rows = try context.fetch(FetchDescriptor<StoredAthleteRecord>(predicate: predicate))
		var records: [AthleteRecord] = []
		var skipped: [SkippedRow] = []
		for row in rows {
			switch row.decode() {
			case .success(let record):
				if recordMatches(record, query) {
					records.append(record)
				}
			case .failure(let reason):
				skipped.append(reason)
			}
		}
		return RecordPage(records: records.sorted { $0.hlc < $1.hlc }, skipped: skipped)
	}

	package var imports: AsyncStream<Void> {
		AsyncStream { continuation in
			let task = Task {
				let changes = NotificationCenter.default.notifications(
					named: .NSPersistentStoreRemoteChange)
				for await _ in changes {
					continuation.yield()
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	private func container(for locality: RecordLocality) -> ModelContainer {
		switch locality {
		case .synced: synced
		case .deviceLocal: local
		}
	}
}

package struct ModelContainerHandle: Sendable {
	let container: ModelContainer
}

func recordMatches(_ record: AthleteRecord, _ query: RecordQuery) -> Bool {
	guard query.scope.admits(record.body) else { return false }
	if let writtenBy = query.writtenBy, record.deviceId != writtenBy {
		return false
	}
	if let from = query.from, record.civilDate < from {
		return false
	}
	if let to = query.to, record.civilDate > to {
		return false
	}
	if let chatId = query.chatId, record.chatId != chatId {
		return false
	}
	if let turn = query.turn, record.body.turn != turn {
		return false
	}
	return true
}
