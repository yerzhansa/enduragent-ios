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
	}

	package var operation: Operation

	package init(operation: Operation) {
		self.operation = operation
	}
}

package final class FaultInjectingRecordLog: RecordLog, Sendable {
	private struct Faults: Sendable {
		var nextAppend = false
		var syncedAppends = false
		var syncedAcknowledgments = false
		var appendKinds: Set<String> = []
		var fetches = false
		var nextFetch: RecordQuery.Scope?
		var recoveryReads = false
	}

	package let deviceId: DeviceID
	private let wrapped: any RecordLog
	private let faults = Mutex(Faults())

	package init(wrapping wrapped: any RecordLog) {
		self.deviceId = wrapped.deviceId
		self.wrapped = wrapped
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

	package func failNextFetch(in scope: RecordQuery.Scope) {
		faults.withLock { $0.nextFetch = scope }
	}

	package func failAppends(ofKind kind: String) throws {
		guard
			SyncedKind(rawValue: kind) != nil || DeviceLocalKind(rawValue: kind) != nil
		else {
			throw RecordFaultConfigurationError.unknownKind(kind)
		}
		faults.withLock { _ = $0.appendKinds.insert(kind) }
	}

	package func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let kinds = batch.map(\.body.kind)
		let fails = faults.withLock { current -> Bool in
			if current.nextAppend {
				current.nextAppend = false
				return true
			}
			return (current.syncedAppends && locality == .synced)
				|| kinds.contains { current.appendKinds.contains($0) }
		}
		if fails {
			throw RecordStorageFault(operation: .append(kinds: kinds))
		}
		try await wrapped.append(batch, locality: locality)
		if locality == .synced, failSyncedAcknowledgments {
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
		let fails = faults.withLock { current -> Bool in
			if current.nextFetch == query.scope {
				current.nextFetch = nil
				return true
			}
			return current.fetches
				|| (current.recoveryReads && query.scope == TurnRecovery.localScope)
		}
		if fails {
			throw RecordStorageFault(operation: .fetch)
		}
		return try await wrapped.fetch(query)
	}

	package var imports: AsyncStream<Void> {
		wrapped.imports
	}
}
