import CoreData
import Foundation
import SwiftData
import Synchronization

public struct RecordQuery: Sendable, Equatable {
	public enum Scope: Sendable, Equatable {
		case synced(Set<SyncedKind>, includeLegacy: Set<LegacyKind>)
		case deviceLocal(Set<DeviceLocalKind>)

		public static func synced(_ kinds: Set<SyncedKind>) -> Scope {
			.synced(kinds, includeLegacy: [])
		}

		public static let everySynced: Scope = .synced(
			Set(SyncedKind.allCases), includeLegacy: Set(LegacyKind.allCases))
		public static let everyDeviceLocal: Scope = .deviceLocal(Set(DeviceLocalKind.allCases))

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

	public var scope: Scope
	public var chatId: ChatID?
	public var turn: TurnID?
	public var from: CivilDate?
	public var to: CivilDate?
	public var writtenBy: DeviceID?

	public init(
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

public protocol RecordLog: Sendable {
	var deviceId: DeviceID { get }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws
	func fetch(_ query: RecordQuery) async throws -> RecordPage
	var imports: AsyncStream<Void> { get }
}

public struct RecordPage: Sendable, Equatable {
	public let records: [AthleteRecord]
	public let skipped: [SkippedRow]

	public init(records: [AthleteRecord], skipped: [SkippedRow]) {
		self.records = records
		self.skipped = skipped
	}
}

public enum SkippedRow: Error, Sendable, Hashable {
	case newerKind(kind: String, ulid: String)
	case newerVersion(kind: String, version: Int, ulid: String)
	case malformed(kind: String, ulid: String)
}

public struct RecordDecodeFailure: Error, Sendable, Equatable {
	public var reason: String

	public init(reason: String) {
		self.reason = reason
	}
}

public final class InMemoryRecordLog: RecordLog, @unchecked Sendable {
	public let deviceId: DeviceID
	private let records = Mutex<[AthleteRecord]>([])

	public init(deviceId: DeviceID = DeviceID()) {
		self.deviceId = deviceId
	}

	public func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		records.withLock { $0.append(contentsOf: batch) }
	}

	public func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let matching = records.withLock { $0.filter { recordMatches($0, query) } }
		return RecordPage(records: matching.sorted { $0.hlc < $1.hlc }, skipped: [])
	}

	public var imports: AsyncStream<Void> {
		AsyncStream { _ in }
	}
}

public struct SwiftDataRecordLog: RecordLog {
	public let deviceId: DeviceID
	private let synced: ModelContainer
	private let local: ModelContainer

	public init(deviceId: DeviceID, synced: ModelContainerHandle, local: ModelContainerHandle) {
		self.deviceId = deviceId
		self.synced = synced.container
		self.local = local.container
	}

	public func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let context = ModelContext(container(for: locality))
		context.autosaveEnabled = false
		for record in batch {
			context.insert(try StoredAthleteRecord(record: record))
		}
		try context.save()
	}

	public func fetch(_ query: RecordQuery) async throws -> RecordPage {
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

	public var imports: AsyncStream<Void> {
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

public struct ModelContainerHandle: Sendable {
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
