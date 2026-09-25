import Foundation
import Synchronization

public struct RecordStorageFault: Error, Sendable, Equatable {
	public enum Operation: Sendable, Equatable {
		case append(RecordKind)
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
		var appendKinds: Set<RecordKind> = []
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

	public func failAppends(ofKind kind: RecordKind) {
		faults.withLock { _ = $0.appendKinds.insert(kind) }
	}

	public func append(_ record: AthleteRecord) async throws {
		let kind = record.body.kind
		let fails = faults.withLock { current -> Bool in
			if current.nextAppend {
				current.nextAppend = false
				return true
			}
			return current.appendKinds.contains(kind)
		}
		if fails {
			throw RecordStorageFault(operation: .append(kind))
		}
		try await wrapped.append(record)
	}

	public func fetch(_ query: RecordQuery) async throws -> [AthleteRecord] {
		if faults.withLock({ $0.fetches }) {
			throw RecordStorageFault(operation: .fetch)
		}
		return try await wrapped.fetch(query)
	}
}
