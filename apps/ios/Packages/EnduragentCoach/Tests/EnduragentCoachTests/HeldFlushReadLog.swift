import Foundation
import Synchronization

@testable import EnduragentCoach

final class HeldFlushReadLog: RecordLog, Sendable {
	let inner: any RecordLog
	let reached: AsyncStream<Void>
	private let reachedContinuation: AsyncStream<Void>.Continuation
	private let state = Mutex<(armed: Bool, held: CheckedContinuation<Void, Never>?)>((false, nil))

	init(inner: any RecordLog) {
		self.inner = inner
		(reached, reachedContinuation) = AsyncStream.makeStream()
	}

	var deviceId: DeviceID { inner.deviceId }

	func holdNextChatFlushRead() {
		state.withLock { $0.armed = true }
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let hold = state.withLock { current -> Bool in
			guard current.armed, query.scope == ConversationFold.flushScope, query.chatId != nil
			else { return false }
			current.armed = false
			return true
		}
		if hold {
			await withCheckedContinuation { continuation in
				state.withLock { $0.held = continuation }
				reachedContinuation.yield()
			}
		}
		return try await inner.fetch(query)
	}

	func release() {
		state.withLock { current in
			current.held?.resume()
			current.held = nil
		}
	}

	var imports: AsyncStream<Void> { inner.imports }
}
