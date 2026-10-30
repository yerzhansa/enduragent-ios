import EnduragentCoach
import Foundation
import Synchronization

package enum RecordFaultConfigurationError: Error, Equatable {
	case unknownKind(String)
}

package struct RecordStorageFault: Error, Sendable, Equatable {
	package enum Operation: Sendable, Equatable {
		case append(kinds: [String])
		case fetch
		case erase
	}

	package var operation: Operation

	package init(operation: Operation) {
		self.operation = operation
	}
}

public enum FixtureExport: String, Sendable, CaseIterable {
	case confirmed
	case noAccount = "no-account"
	case held
}

package final class FaultInjectingRecordLog: ReviewChainLog, Sendable {
	private struct Faults: Sendable {
		var erasures: Set<RecordLocality> = []
		var export = FixtureExport.confirmed
		var nextAppend = false
		var syncedAppends = false
		var syncedAcknowledgments = false
		var appendKinds: Set<String> = []
		var heldKinds: Set<String> = []
		var chosenAppend: (kind: String, skipping: Int)?
		var appendsBeforeRefusal: Int?
		var fetches = false
		var nextFetch: (scope: RecordQuery.Scope, skipping: Int)?
		var failedFetches = 0
		var recoveryReads = false
	}

	package let deviceId: DeviceID
	private let storage: Mutex<(any ReviewChainLog)?>
	private let release: FixtureStoreRelease?
	private let faults = Mutex(Faults())

	package init(wrapping wrapped: any ReviewChainLog, release: FixtureStoreRelease? = nil) {
		self.deviceId = wrapped.deviceId
		self.storage = Mutex(wrapped)
		self.release = release
	}

	deinit {
		autoreleasepool { storage.withLock { $0 = nil } }
		release?.finish()
	}

	private var wrapped: any ReviewChainLog {
		storage.withLock {
			guard let log = $0 else { preconditionFailure("The record log has been released") }
			return log
		}
	}

	package var failNextAppend: Bool {
		get { faults.withLock { $0.nextAppend } }
		set { faults.withLock { $0.nextAppend = newValue } }
	}

	package var failFetches: Bool {
		get { faults.withLock { $0.fetches } }
		set { faults.withLock { $0.fetches = newValue } }
	}

	package var failSyncedAppends: Bool {
		get { faults.withLock { $0.syncedAppends } }
		set { faults.withLock { $0.syncedAppends = newValue } }
	}

	package var failSyncedAcknowledgments: Bool {
		get { faults.withLock { $0.syncedAcknowledgments } }
		set { faults.withLock { $0.syncedAcknowledgments = newValue } }
	}

	package var failRecoveryReads: Bool {
		get { faults.withLock { $0.recoveryReads } }
		set { faults.withLock { $0.recoveryReads = newValue } }
	}

	package var failedFetchCount: Int { faults.withLock { $0.failedFetches } }

	package var failErasures: Set<RecordLocality> {
		get { faults.withLock { $0.erasures } }
		set { faults.withLock { $0.erasures = newValue } }
	}

	package var export: FixtureExport {
		get { faults.withLock { $0.export } }
		set { faults.withLock { $0.export = newValue } }
	}

	package func erase(_ locality: RecordLocality, sparing kept: DeviceID?) async throws -> Int {
		if failErasures.contains(locality) {
			throw RecordStorageFault(operation: .erase)
		}
		return try await wrapped.erase(locality, sparing: kept)
	}

	package func confirmSyncedExport(after saved: Date) async throws -> Bool {
		switch export {
		case .confirmed: return true
		case .noAccount: return false
		case .held:
			try await Task.sleep(for: .milliseconds(20))
			return try await confirmSyncedExport(after: saved)
		}
	}

	package func failNextFetch(in scope: RecordQuery.Scope, skipping: Int = 0) {
		faults.withLock { $0.nextFetch = (scope, skipping) }
	}

	package func failAppends(ofKind kind: String) throws {
		guard
			SyncedKind(rawValue: kind) != nil || DeviceLocalKind(rawValue: kind) != nil
		else {
			throw RecordFaultConfigurationError.unknownKind(kind)
		}
		faults.withLock { _ = $0.appendKinds.insert(kind) }
	}

	package func holdAppends(ofKind kind: String) throws {
		guard SyncedKind(rawValue: kind) != nil || DeviceLocalKind(rawValue: kind) != nil else {
			throw RecordFaultConfigurationError.unknownKind(kind)
		}
		faults.withLock { _ = $0.heldKinds.insert(kind) }
	}

	package func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let kinds = batch.map(\.body.kind)
		try await holdIfAsked(appending: kinds)
		try failIfAsked(appending: kinds, locality: locality)
		try await wrapped.append(batch, locality: locality)
		if locality == .synced, failSyncedAcknowledgments {
			throw RecordStorageFault(operation: .append(kinds: kinds))
		}
	}

	package func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
	{
		try await holdIfAsked(appending: [record.body.kind])
		try failIfAsked(appending: [record.body.kind], locality: record.locality)
		try await wrapped.append(record, after: head, in: query)
	}

	private func holdIfAsked(appending kinds: [String]) async throws {
		let held = faults.withLock { current in kinds.contains { current.heldKinds.contains($0) } }
		guard held else { return }
		repeat {
			try await Task.sleep(for: .seconds(60))
		} while true
	}

	package func failAppend(ofKind kind: String, skipping: Int) throws {
		guard SyncedKind(rawValue: kind) != nil || DeviceLocalKind(rawValue: kind) != nil else {
			throw RecordFaultConfigurationError.unknownKind(kind)
		}
		faults.withLock { $0.chosenAppend = (kind, skipping) }
	}

	package func refuseEveryAppend(after appends: Int) {
		faults.withLock { $0.appendsBeforeRefusal = appends }
	}

	private func failIfAsked(appending kinds: [String], locality: RecordLocality) throws {
		let fails = faults.withLock { current -> Bool in
			if let left = current.appendsBeforeRefusal {
				guard left > 0 else { return true }
				current.appendsBeforeRefusal = left - 1
			}
			if current.nextAppend {
				current.nextAppend = false
				return true
			}
			if let chosen = current.chosenAppend, kinds.contains(chosen.kind) {
				guard chosen.skipping > 0 else {
					current.chosenAppend = nil
					return true
				}
				current.chosenAppend = (chosen.kind, chosen.skipping - 1)
			}
			return (current.syncedAppends && locality == .synced)
				|| kinds.contains { current.appendKinds.contains($0) }
		}
		if fails {
			throw RecordStorageFault(operation: .append(kinds: kinds))
		}
	}

	package func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor?
	{
		if failFetches {
			throw RecordStorageFault(operation: .fetch)
		}
		return try await wrapped.latest(locality: locality, writtenBy: writtenBy)
	}

	package func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try failIfAsked(reading: query)
		return try await wrapped.fetch(query)
	}

	package func newest(_ query: RecordQuery) async throws -> NewestRecord {
		try failIfAsked(reading: query)
		return try await wrapped.newest(query)
	}

	package func chats(holding scope: RecordQuery.Scope) async throws -> Set<ChatID> {
		try failIfAsked(reading: RecordQuery(scope: scope))
		return try await wrapped.chats(holding: scope)
	}

	private func failIfAsked(reading query: RecordQuery) throws {
		let fails = faults.withLock { current -> Bool in
			if let next = current.nextFetch, next.scope == query.scope {
				if next.skipping == 0 {
					current.nextFetch = nil
					current.failedFetches += 1
					return true
				}
				current.nextFetch = (next.scope, next.skipping - 1)
			}
			return current.fetches
				|| (current.recoveryReads && query.scope == TurnRecovery.localScope)
		}
		if fails {
			throw RecordStorageFault(operation: .fetch)
		}
	}

	package var imports: AsyncStream<Void> {
		wrapped.imports
	}
}
