import Foundation
import Synchronization

final class SnapshotFeed: Sendable {
	private let observers = Mutex<[UUID: AsyncStream<ChatSnapshot>.Continuation]>([:])

	func subscribe(from first: ChatSnapshot) -> AsyncStream<ChatSnapshot> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<ChatSnapshot>.makeStream(
			bufferingPolicy: .unbounded)
		continuation.onTermination = { [weak self] _ in
			self?.observers.withLock { _ = $0.removeValue(forKey: id) }
		}
		observers.withLock { $0[id] = continuation }
		continuation.yield(first)
		return stream
	}

	func publish(_ snapshot: ChatSnapshot) {
		for continuation in observers.withLock({ Array($0.values) }) {
			continuation.yield(snapshot)
		}
	}
}
