import Foundation
import Synchronization

@testable import EnduragentCoach

final class HeldFirstReadLog: RecordLog, Sendable {
	let inner: any RecordLog
	let reached: AsyncStream<Void>
	private let continuation: AsyncStream<Void>.Continuation
	private let state = Mutex<(claimed: Bool, wake: CheckedContinuation<Void, Never>?)>(
		(false, nil))

	init(inner: any RecordLog) {
		self.inner = inner
		(reached, continuation) = AsyncStream.makeStream()
	}

	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		await holdIfNeeded()
		return try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		await holdIfNeeded()
		return try await inner.fetch(query)
	}

	private func holdIfNeeded() async {
		let shouldHold = state.withLock { current in
			guard !current.claimed else { return false }
			current.claimed = true
			return true
		}
		if shouldHold {
			await withCheckedContinuation { wake in
				state.withLock { $0.wake = wake }
				continuation.yield()
			}
		}
	}

	func release() {
		state.withLock { current in
			current.wake?.resume()
			current.wake = nil
		}
	}
}
