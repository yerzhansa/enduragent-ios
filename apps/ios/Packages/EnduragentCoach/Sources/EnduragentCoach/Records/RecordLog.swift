import Foundation
import SwiftData
import Synchronization

public struct RecordQuery: Sendable, Equatable {
	public var kinds: Set<RecordKind>
	public var chatId: ChatID?
	public var from: CivilDate?
	public var to: CivilDate?
	public var deviceLocalOnly: Bool

	public init(
		kinds: Set<RecordKind>,
		chatId: ChatID? = nil,
		from: CivilDate? = nil,
		to: CivilDate? = nil,
		deviceLocalOnly: Bool = false
	) {
		self.kinds = kinds
		self.chatId = chatId
		self.from = from
		self.to = to
		self.deviceLocalOnly = deviceLocalOnly
	}
}

public protocol RecordLog: Sendable {
	var deviceId: DeviceID { get }

	func append(_ record: AthleteRecord) async throws
	func fetch(_ query: RecordQuery) async throws -> [AthleteRecord]
}

public struct ForeignDeviceLocalRecord: Error, Sendable, Equatable {
	public var recordDeviceId: DeviceID
	public var logDeviceId: DeviceID

	public init(recordDeviceId: DeviceID, logDeviceId: DeviceID) {
		self.recordDeviceId = recordDeviceId
		self.logDeviceId = logDeviceId
	}
}

public struct MixedRecordLocalityQuery: Error, Sendable, Equatable {
	public var kinds: Set<RecordKind>

	public init(kinds: Set<RecordKind>) {
		self.kinds = kinds
	}
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

	public func append(_ record: AthleteRecord) async throws {
		if record.locality == .deviceLocal, record.deviceId != deviceId {
			throw ForeignDeviceLocalRecord(recordDeviceId: record.deviceId, logDeviceId: deviceId)
		}
		records.withLock { $0.append(record) }
	}

	public func fetch(_ query: RecordQuery) async throws -> [AthleteRecord] {
		records.withLock { $0.filter { recordMatches($0, query, logDeviceId: deviceId) } }
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

	public func append(_ record: AthleteRecord) async throws {
		if record.locality == .deviceLocal, record.deviceId != deviceId {
			throw ForeignDeviceLocalRecord(recordDeviceId: record.deviceId, logDeviceId: deviceId)
		}
		let context = ModelContext(container(for: record.locality))
		context.insert(try StoredAthleteRecord(record: record))
		try context.save()
	}

	public func fetch(_ query: RecordQuery) async throws -> [AthleteRecord] {
		if query.kinds.isEmpty {
			return []
		}
		let localities = Set(query.kinds.map(\.locality))
		guard localities.count == 1, let locality = localities.first else {
			throw MixedRecordLocalityQuery(kinds: query.kinds)
		}
		let context = ModelContext(container(for: locality))
		let rows = try context.fetch(FetchDescriptor<StoredAthleteRecord>())
		return try rows.map { try $0.athleteRecord() }
			.filter { recordMatches($0, query, logDeviceId: deviceId) }
			.sorted { $0.hlc < $1.hlc }
	}

	private func container(for locality: RecordLocality) -> ModelContainer {
		switch locality {
		case .synced: return synced
		case .deviceLocal: return local
		}
	}
}

public struct ModelContainerHandle: Sendable {
	let container: ModelContainer
}

@Model
final class StoredAthleteRecord {
	var ulid: String = ""
	var deviceId: String = ""
	var hlcWallMs: Int64 = 0
	var hlcLogical: Int64 = 0
	var hlcDeviceId: String = ""
	var timeZone: String = ""
	var civilDate: String = ""
	var kind: String = ""
	var body: Data = Data()

	init(record: AthleteRecord) throws {
		self.ulid = record.ulid.rawValue
		self.deviceId = record.deviceId.rawValue
		self.hlcWallMs = record.hlc.wallMs
		self.hlcLogical = Int64(record.hlc.logical)
		self.hlcDeviceId = record.hlc.deviceId.rawValue
		self.timeZone = record.timeZone.identifier
		self.civilDate = record.civilDate.rawValue
		self.kind = record.body.kind.rawValue
		self.body = try encodeRecordBody(record.body)
	}

	func athleteRecord() throws -> AthleteRecord {
		guard let ulid = ULID(rawValue: ulid) else {
			throw RecordDecodeFailure(reason: "ulid")
		}
		guard let timeZone = IANATimeZone(identifier: timeZone) else {
			throw RecordDecodeFailure(reason: "timeZone")
		}
		guard let civilDate = CivilDate(rawValue: civilDate) else {
			throw RecordDecodeFailure(reason: "civilDate")
		}
		let body = try decodeRecordBody(body)
		if body.kind.rawValue != kind {
			throw RecordDecodeFailure(reason: "kind")
		}
		return AthleteRecord(
			ulid: ulid,
			deviceId: DeviceID(rawValue: deviceId),
			hlc: HybridLogicalClock(
				wallMs: hlcWallMs,
				logical: UInt32(hlcLogical),
				deviceId: DeviceID(rawValue: hlcDeviceId)
			),
			timeZone: timeZone,
			civilDate: civilDate,
			body: body
		)
	}
}

func recordMatches(_ record: AthleteRecord, _ query: RecordQuery, logDeviceId: DeviceID) -> Bool {
	guard query.kinds.contains(record.body.kind) else { return false }
	if record.locality == .deviceLocal, record.deviceId != logDeviceId {
		return false
	}
	if query.deviceLocalOnly, record.deviceId != logDeviceId {
		return false
	}
	if let from = query.from, record.civilDate < from {
		return false
	}
	if let to = query.to, record.civilDate > to {
		return false
	}
	if let chatId = query.chatId {
		guard let recordChatId = recordChatId(record.body), recordChatId == chatId else {
			return false
		}
	}
	return true
}

func recordChatId(_ body: RecordBody) -> ChatID? {
	switch body {
	case .userMessage(let body): return body.chatId
	case .assistantMessage(let body): return body.chatId
	case .windowStart(let body): return body.chatId
	case .compactionSummary(let body): return body.chatId
	case .pendingProposal(let body): return body.chatId
	case .proposalCleared(let body): return body.chatId
	case .flushPending(let body): return body.chatId
	default: return nil
	}
}

public enum RecordLogSamples {
	public static func userMessage(text: String) -> RecordBody {
		.userMessage(UserMessageBody(chatId: .main, athleteText: text, timedText: text, slash: nil))
	}

	public static func pendingProposal(expiresAt: Date) -> RecordBody {
		.pendingProposal(
			ProposalBody(
				chatId: .main,
				nonce: Nonce(),
				tool: .intervalsCreateStrengthWorkout,
				toolInput: .createStrengthWorkout(
					date: "1998-06-13", name: "Core", description: "20 min"),
				summary: "Core session",
				description: "Core · 20 min",
				expiresAt: expiresAt
			)
		)
	}

	public static func record(deviceId: DeviceID, now: Date, body: RecordBody) -> AthleteRecord {
		AthleteRecord(
			ulid: ULID.generate(at: now),
			deviceId: deviceId,
			hlc: HybridLogicalClock.tick(now: now, deviceId: deviceId, last: nil),
			timeZone: IANATimeZone(identifier: TimeZone.current.identifier) ?? .gmt,
			civilDate: CivilDate(date: now, timeZone: .current),
			body: body
		)
	}
}
