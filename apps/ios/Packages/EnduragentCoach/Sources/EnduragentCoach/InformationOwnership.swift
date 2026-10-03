import Foundation

package enum InformationOwner: Hashable, Sendable {
	case athlete(IntervalsAthleteID)
	case unbound(DeviceID)
	case unverified
}

package enum InformationReadScope: Sendable {
	case athlete(IntervalsAthleteID)
	case beforeFirstConnection(DeviceID)
	case unavailable

	func contains(_ owner: InformationOwner) -> Bool {
		switch (self, owner) {
		case (.athlete(let selected), .athlete(let saved)): selected == saved
		case (.beforeFirstConnection(let selected), .unbound(let saved)): selected == saved
		default: false
		}
	}
}

package struct InformationOwnership: Sendable, Equatable {
	package static let syncedScope: RecordQuery.Scope = .synced(
		[
			.trainingIdentityObserved, .userMessage, .turnSettled, .windowStart,
			.compactionSummary, .memorySection, .dailyNote, .ledgerEvent, .journal,
			.reviewApplied, .reviewWrite,
		], includeLegacy: [.userMessage, .assistantMessage])
	package static let localScope: RecordQuery.Scope = .deviceLocal([
		.turnClaim, .pendingSettlement, .flushPending, .pendingProposal,
	])

	private let records: [ULID: AthleteRecord]
	private let connections: [ConnectionID: Set<IntervalsAthleteID>]
	private let firstAccounts: [DeviceID: TrainingAccount]
	private let claims: [TurnID: [AthleteRecord]]

	package init(records: [AthleteRecord]) {
		let ordered = records.sorted { $0.hlc < $1.hlc }
		self.records = Dictionary(
			ordered.map { ($0.ulid, $0) }, uniquingKeysWith: { first, _ in first })
		var connections: [ConnectionID: Set<IntervalsAthleteID>] = [:]
		var claims: [TurnID: [AthleteRecord]] = [:]
		for record in ordered {
			if case .intervals(let connection, let athlete?) = record.account {
				connections[connection, default: []].insert(athlete)
			}
			if case .deviceLocal(.turnClaim(let claim)) = record.body {
				claims[claim.turn, default: []].append(record)
			}
		}
		self.connections = connections
		self.claims = claims
		var first: [DeviceID: TrainingAccount] = [:]
		for record in ordered where record.body == .synced(.trainingIdentityObserved) {
			if case .intervals(_, .some) = record.account, first[record.deviceId] == nil {
				first[record.deviceId] = record.account
			}
		}
		for record in ordered where first[record.deviceId] == nil {
			if case .intervals(let connection, let saved) = record.account,
				let athlete = saved ?? Self.uniqueAthlete(connections[connection])
			{
				first[record.deviceId] = .intervals(connection: connection, athlete: athlete)
			}
		}
		firstAccounts = first
	}

	func including(_ added: [AthleteRecord]) -> InformationOwnership {
		InformationOwnership(records: Array(records.values) + added)
	}

	package func firstAccount(on device: DeviceID) -> TrainingAccount? {
		firstAccounts[device]
	}

	package func scope(for account: TrainingAccount, device: DeviceID) -> InformationReadScope {
		switch account {
		case .unconnected:
			return firstAccounts[device] == nil ? .beforeFirstConnection(device) : .unavailable
		case .intervals(_, let athlete?):
			return .athlete(athlete)
		case .intervals(_, nil):
			return .unavailable
		}
	}

	package func rowOwner(account: TrainingAccount) -> InformationOwner {
		guard case .intervals(let connection, let saved) = account,
			let athlete = saved ?? Self.uniqueAthlete(connections[connection])
		else { return .unverified }
		return .athlete(athlete)
	}

	func rowOwner(account: TrainingAccount, origin: DeviceID) -> InformationOwner {
		account == .unconnected ? .unbound(origin) : rowOwner(account: account)
	}

	package func memoryOwner(account: TrainingAccount, origin: DeviceID) -> InformationOwner {
		guard account == .unconnected else { return rowOwner(account: account) }
		guard let first = firstAccounts[origin] else { return .unbound(origin) }
		return rowOwner(account: first)
	}

	package func recoveredMemoryAccount(of record: AthleteRecord) -> TrainingAccount {
		guard record.account == .unconnected else { return record.account }
		return sourceAccount(for: record.cause)
	}

	func extractionReadAccount(for stamp: OperationStamp, origin: DeviceID) -> TrainingAccount {
		guard stamp.binding.account == .unconnected else { return stamp.binding.account }
		let source = sourceAccount(for: .operation(stamp.operation, stamp.attempt))
		return source == .unconnected ? firstAccounts[origin] ?? .unconnected : source
	}

	private func sourceAccount(for cause: RecordCause) -> TrainingAccount {
		guard case .operation(let operation, let attempt) = cause else { return .unconnected }
		switch operation {
		case .turn(let turn):
			return claims[turn]?.first { $0.cause == .operation(operation, attempt) }?.account
				?? .unconnected
		case .memoryFlush(let job):
			guard let source = records[job.ulid],
				case .deviceLocal(.flushPending(let body)) = source.body,
				!body.messageUlids.isEmpty
			else { return .unconnected }
			let accounts = body.messageUlids.compactMap { records[$0].map(rowAccount) }
			guard accounts.count == body.messageUlids.count, let first = accounts.first,
				accounts.allSatisfy({ rowOwner(account: $0) == rowOwner(account: first) }),
				rowOwner(account: first) != .unverified
			else { return .unconnected }
			return first
		default:
			return .unconnected
		}
	}

	private func rowAccount(_ record: AthleteRecord) -> TrainingAccount {
		switch record.body {
		case .synced(.userMessage(let body)):
			return claims[body.turn]?.first?.account ?? record.account
		case .synced(.turnSettled(let body)), .deviceLocal(.pendingSettlement(let body)):
			return claims[body.turn]?.first {
				if case .deviceLocal(.turnClaim(let claim)) = $0.body {
					return claim.attempt == body.attempt
				}
				return false
			}?.account ?? record.account
		default:
			return record.account
		}
	}

	private static func uniqueAthlete(_ athletes: Set<IntervalsAthleteID>?) -> IntervalsAthleteID? {
		guard let athletes, athletes.count == 1 else { return nil }
		return athletes.first
	}
}

extension Ledger {
	func informationRecords() async throws(LedgerFailure) -> [AthleteRecord] {
		let synced = try await read(RecordQuery(scope: InformationOwnership.syncedScope)).records
		let local = try await read(RecordQuery(scope: InformationOwnership.localScope)).records
		return synced + local
	}

	func informationOwnership() async throws(LedgerFailure) -> InformationOwnership {
		InformationOwnership(records: try await informationRecords())
	}
}
