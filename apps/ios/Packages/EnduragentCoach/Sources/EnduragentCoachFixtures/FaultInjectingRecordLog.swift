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
		var appendKinds: Set<String> = []
		var fetches = false
		var recoveryReads = false
	}

	package let deviceId: DeviceID
	private let storage: Mutex<(any RecordLog)?>
	private let release: FixtureStoreRelease?
	private let faults = Mutex(Faults())

	package init(wrapping wrapped: any RecordLog, release: FixtureStoreRelease? = nil) {
		self.deviceId = wrapped.deviceId
		self.storage = Mutex(wrapped)
		self.release = release
	}

	deinit {
		autoreleasepool { storage.withLock { $0 = nil } }
		release?.finish()
	}

	private var wrapped: any RecordLog {
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

	package var failRecoveryReads: Bool {
		get { faults.withLock { $0.recoveryReads } }
		set { faults.withLock { $0.recoveryReads = newValue } }
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
	}

	package func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor?
	{
		if failFetches {
			throw RecordStorageFault(operation: .fetch)
		}
		return try await wrapped.latest(locality: locality, writtenBy: writtenBy)
	}

	package func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let fails = faults.withLock { current in
			current.fetches || (current.recoveryReads && query.scope == TurnRecovery.localScope)
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
