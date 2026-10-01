import Foundation
import Synchronization

@testable import EnduragentCoach

final class ImportingRecordLog: RecordLog, Sendable {
	private struct State {
		var subscriptions = 0
		var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
		var nextRead: Gate?
	}

	let inner: any RecordLog
	private let state = Mutex(State())

	init(inner: any RecordLog = InMemoryRecordLog()) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }
	var subscriptions: Int { state.withLock { $0.subscriptions } }
	var listeners: Int { state.withLock { $0.listeners.count } }

	var imports: AsyncStream<Void> {
		let id = UUID()
		return AsyncStream { continuation in
			state.withLock {
				$0.subscriptions += 1
				$0.listeners[id] = continuation
			}
			continuation.onTermination = { [weak self] _ in
				self?.state.withLock { $0.listeners[id] = nil }
			}
		}
	}

	func notifyImport() {
		let listeners = state.withLock { Array($0.listeners.values) }
		for listener in listeners { listener.yield() }
	}

	func holdRead() -> Gate {
		let gate = Gate()
		state.withLock { $0.nextRead = gate }
		return gate
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let page = try await inner.fetch(query)
		let gate = state.withLock { current -> Gate? in
			guard query.scope == ConversationFold.syncedScope else { return nil }
			defer { current.nextRead = nil }
			return current.nextRead
		}
		try await gate?.waitUnlessCancelled()
		return page
	}
}

final class ImportSnapshots: Sendable {
	private let snapshots = Mutex<[ChatSnapshot]>([])
	private let task = Mutex<Task<Void, Never>?>(nil)

	init(_ stream: AsyncStream<ChatSnapshot>) {
		task.withLock {
			$0 = Task { [weak self] in
				for await snapshot in stream {
					self?.snapshots.withLock { $0.append(snapshot) }
				}
			}
		}
	}

	deinit { task.withLock { $0?.cancel() } }

	var latest: ChatSnapshot? { snapshots.withLock { $0.last } }
	var count: Int { snapshots.withLock { $0.count } }
}
