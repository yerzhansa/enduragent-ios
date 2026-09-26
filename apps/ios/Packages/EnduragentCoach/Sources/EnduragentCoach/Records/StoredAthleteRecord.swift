import Foundation
import SwiftData

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

	func decode() -> Result<AthleteRecord, SkippedRow> {
		guard let ulid = ULID(rawValue: ulid),
			let timeZone = IANATimeZone(identifier: timeZone),
			let civilDate = CivilDate(rawValue: civilDate),
			let account = TrainingAccount(storedValue: account)
		else {
			return .failure(.malformed(kind: kind, ulid: self.ulid))
		}
		let cause: RecordCause
		switch (operation, attempt) {
		case (nil, nil):
			cause = .legacy
		case (let operation?, let attempt?):
			guard let parsed = OperationID(storedValue: operation),
				let attemptUlid = ULID(rawValue: attempt)
			else {
				return .failure(.malformed(kind: kind, ulid: self.ulid))
			}
			cause = .operation(parsed, AttemptID(ulid: attemptUlid))
		default:
			return .failure(.malformed(kind: kind, ulid: self.ulid))
		}
		return RecordCodec.decode(
			kind: kind, version: bodyVersion, data: body, civilDate: civilDate, ulid: self.ulid
		).map { body in
			AthleteRecord(
				ulid: ulid,
				deviceId: DeviceID(rawValue: deviceId),
				hlc: HybridLogicalClock(
					wallMs: hlcWallMs,
					logical: UInt32(hlcLogical),
					deviceId: DeviceID(rawValue: hlcDeviceId)
				),
				timeZone: timeZone,
				civilDate: civilDate,
				cause: cause,
				account: account,
				body: body
			)
		}
	}
}

extension OperationID {
	var storedValue: String {
		switch self {
		case .turn(let id): "turn:\(id.ulid.rawValue)"
		case .memoryFlush(let id): "memoryFlush:\(id.ulid.rawValue)"
		case .conversationReset(let id): "conversationReset:\(id.ulid.rawValue)"
		case .preferenceChange(let id): "preferenceChange:\(id.ulid.rawValue)"
		case .credentialChange(let id): "credentialChange:\(id.ulid.rawValue)"
		case .launchRecovery(let id): "launchRecovery:\(id.ulid.rawValue)"
		case .workoutChangeSet(let id, let revision):
			"workoutChangeSet:\(id.ulid.rawValue):\(revision.rawValue)"
		case .planningCommand(let id): "planningCommand:\(id.rawValue)"
		case .referenceRefresh(let id): "referenceRefresh:\(id.ulid.rawValue)"
		case .debugSample(let id): "debugSample:\(id.ulid.rawValue)"
		}
	}

	init?(storedValue: String) {
		let parts = storedValue.split(
			separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
		guard parts.count == 2 else { return nil }
		let name = parts[0]
		let rest = String(parts[1])
		if name == "planningCommand" {
			self = .planningCommand(PlanningCommandID(rawValue: rest))
			return
		}
		if name == "workoutChangeSet" {
			let fields = rest.split(separator: ":")
			guard fields.count == 2, let ulid = ULID(rawValue: String(fields[0])),
				let revision = Int(fields[1])
			else { return nil }
			self = .workoutChangeSet(ChangeSetID(ulid: ulid), ChangeSetRevision(rawValue: revision))
			return
		}
		guard let ulid = ULID(rawValue: rest) else { return nil }
		switch name {
		case "turn": self = .turn(TurnID(ulid: ulid))
		case "memoryFlush": self = .memoryFlush(FlushJobID(ulid: ulid))
		case "conversationReset": self = .conversationReset(ResetID(ulid: ulid))
		case "preferenceChange": self = .preferenceChange(PreferenceChangeID(ulid: ulid))
		case "credentialChange": self = .credentialChange(CredentialChangeID(ulid: ulid))
		case "launchRecovery": self = .launchRecovery(LaunchID(ulid: ulid))
		case "referenceRefresh": self = .referenceRefresh(RefreshID(ulid: ulid))
		case "debugSample": self = .debugSample(DebugSampleID(ulid: ulid))
		default: return nil
		}
	}
}

extension TrainingAccount {
	var storedValue: String {
		switch self {
		case .unconnected:
			"unconnected"
		case .intervals(let connection, let athlete):
			"intervals:\(connection.rawValue.uuidString):\(athlete?.rawValue ?? "")"
		}
	}

	init?(storedValue: String?) {
		guard let storedValue else {
			self = .unconnected
			return
		}
		if storedValue == "unconnected" {
			self = .unconnected
			return
		}
		let parts = storedValue.split(separator: ":", omittingEmptySubsequences: false)
		guard parts.count == 3, parts[0] == "intervals",
			let uuid = UUID(uuidString: String(parts[1]))
		else { return nil }
		let athlete = IntervalsAthleteID(rawValue: String(parts[2]))
		if !parts[2].isEmpty, athlete == nil {
			return nil
		}
		self = .intervals(connection: ConnectionID(rawValue: uuid), athlete: athlete)
	}
}
