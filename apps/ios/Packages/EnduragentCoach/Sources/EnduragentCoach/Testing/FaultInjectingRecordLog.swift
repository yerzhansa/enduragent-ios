import Foundation
import Synchronization

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
		var appendKinds: Set<String> = []
		var fetches = false
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

	package var failRecoveryReads: Bool {
		get { faults.withLock { $0.recoveryReads } }
		set { faults.withLock { $0.recoveryReads = newValue } }
	}

	package func failAppends(ofKind kind: String) {
		faults.withLock { _ = $0.appendKinds.insert(kind) }
	}

	package func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let kinds = batch.map(\.body.kind)
		let fails = faults.withLock { current -> Bool in
			if current.nextAppend {
				current.nextAppend = false
				return true
			}
			return kinds.contains { current.appendKinds.contains($0) }
		}
		if fails {
			throw RecordStorageFault(operation: .append(kinds: kinds))
		}
		try await wrapped.append(batch, locality: locality)
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
