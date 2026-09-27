import Foundation
import Synchronization

final class SnapshotFeed<Snapshot: Sendable>: Sendable {
	private let observers = Mutex<[UUID: AsyncStream<Snapshot>.Continuation]>([:])

	func subscribe(from first: Snapshot) -> AsyncStream<Snapshot> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<Snapshot>.makeStream(
			bufferingPolicy: .unbounded)
		continuation.onTermination = { [weak self] _ in
			self?.observers.withLock { _ = $0.removeValue(forKey: id) }
		}
		observers.withLock { $0[id] = continuation }
		continuation.yield(first)
		return stream
	}

	func publish(_ snapshot: Snapshot) {
		for continuation in observers.withLock({ Array($0.values) }) {
			continuation.yield(snapshot)
		}
	}
}
