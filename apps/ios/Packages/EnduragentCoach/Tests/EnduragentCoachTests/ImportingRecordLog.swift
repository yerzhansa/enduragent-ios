import EnduragentCoachFixtures
import Foundation
import Synchronization

@testable import EnduragentCoach

final class ImportingRecordLog: RecordLog, Sendable {
	private struct State {
		var subscriptions = 0
		var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
		var nextRead: (scope: RecordQuery.Scope, gate: Gate)?
	}

	let inner: any RecordLog
	private let state = Mutex(State())

	init(inner: any RecordLog = InMemoryRecordLog(), deviceId: DeviceID? = nil) {
		self.inner = inner
		self.deviceId = deviceId ?? inner.deviceId
	}

	let deviceId: DeviceID
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

	func holdRead(scope: RecordQuery.Scope = ConversationFold.syncedScope) -> Gate {
		let gate = Gate()
		state.withLock { $0.nextRead = (scope, gate) }
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
			guard let held = current.nextRead, query.scope == held.scope else { return nil }
			defer { current.nextRead = nil }
			return held.gate
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
