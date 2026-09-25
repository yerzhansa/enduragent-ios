import Foundation
import Synchronization

public struct RecordStorageFault: Error, Sendable, Equatable {
	public enum Operation: Sendable, Equatable {
		case append(kinds: [String])
		case fetch
	}

	public var operation: Operation

	public init(operation: Operation) {
		self.operation = operation
	}
}

public final class FaultInjectingRecordLog: RecordLog, Sendable {
	private struct Faults: Sendable {
		var nextAppend = false
		var appendKinds: Set<String> = []
		var fetches = false
	}

	public let deviceId: DeviceID
	private let wrapped: any RecordLog
	private let faults = Mutex(Faults())

	public init(wrapping wrapped: any RecordLog) {
		self.deviceId = wrapped.deviceId
		self.wrapped = wrapped
	}

	public var failNextAppend: Bool {
		get { faults.withLock { $0.nextAppend } }
		set { faults.withLock { $0.nextAppend = newValue } }
	}

	public var failFetches: Bool {
		get { faults.withLock { $0.fetches } }
		set { faults.withLock { $0.fetches = newValue } }
	}

	public func failAppends(ofKind kind: SyncedKind) {
		faults.withLock { _ = $0.appendKinds.insert(kind.rawValue) }
	}

	public func failAppends(ofKind kind: DeviceLocalKind) {
		faults.withLock { _ = $0.appendKinds.insert(kind.rawValue) }
	}

	public func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
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

	public func fetch(_ query: RecordQuery) async throws -> RecordPage {
		if faults.withLock({ $0.fetches }) {
			throw RecordStorageFault(operation: .fetch)
		}
		return try await wrapped.fetch(query)
	}

	public var imports: AsyncStream<Void> {
		wrapped.imports
	}
}
