import Foundation
import Synchronization

@testable import EnduragentCoach

final class HeldFirstReadLog: ChainForwardingLog, Sendable {
	var chainStore: any ReviewChainLog { inner }
	let inner: any ReviewChainLog
	private let gate = Gate()
	var reached: AsyncStream<Void> { gate.reached }
	private let claimed = Mutex(false)

	init(inner: any ReviewChainLog) {
		self.inner = inner
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
		let shouldHold = claimed.withLock { current in
			guard !current else { return false }
			current = true
			return true
		}
		if shouldHold { await gate.wait() }
	}

	func release() { gate.release() }
}
