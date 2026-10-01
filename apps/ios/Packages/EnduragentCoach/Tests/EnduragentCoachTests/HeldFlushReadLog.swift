import Foundation
import Synchronization

@testable import EnduragentCoach

final class HeldFlushReadLog: RecordLog, Sendable {
	let inner: any RecordLog
	private let gate = Gate()
	var reached: AsyncStream<Void> { gate.reached }
	private let armed = Mutex(false)

	init(inner: any RecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func holdNextChatFlushRead() {
		armed.withLock { $0 = true }
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let hold = armed.withLock { current -> Bool in
			guard current, query.scope == ConversationFold.flushScope, query.chatId != nil
			else { return false }
			current = false
			return true
		}
		if hold { await gate.wait() }
		return try await inner.fetch(query)
	}

	func release() { gate.release() }

	var imports: AsyncStream<Void> { inner.imports }
}
