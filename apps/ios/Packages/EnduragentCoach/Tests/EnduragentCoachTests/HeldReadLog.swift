import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class HeldReadLog: ChainForwardingLog, Sendable {
	enum Read: Sendable, Equatable {
		case fetch(RecordQuery)
		case newest(RecordQuery)
	}

	enum Moment: Sendable {
		case beforeReading, afterReading
	}

	var chainStore: any ReviewChainLog { inner }
	let inner: any ReviewChainLog
	private let read: Read
	private let moment: Moment
	private let gate = Gate()
	private let claimed = Mutex(false)

	init(inner: any ReviewChainLog, holding read: Read, _ moment: Moment) {
		self.inner = inner
		self.read = read
		self.moment = moment
	}

	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await holding(.fetch(query)) { try await inner.fetch(query) }
	}

	func newest(_ query: RecordQuery) async throws -> NewestRecord {
		try await holding(.newest(query)) { try await inner.newest(query) }
	}

	func release() { gate.release() }

	func waitUntilReached() async throws {
		let parked = try await beforeDeadline(within: .hangGuard, onTimeout: release) {
			var arrivals = self.gate.reached.makeAsyncIterator()
			return await arrivals.next() != nil
		}
		try #require(parked == true, "The held read was never reached")
	}

	private func holding<Value>(_ attempt: Read, _ reading: () async throws -> Value)
		async throws -> Value
	{
		let holds =
			attempt == read
			&& claimed.withLock { done in
				guard !done else { return false }
				done = true
				return true
			}
		if holds, moment == .beforeReading { await gate.wait() }
		let value = try await reading()
		if holds, moment == .afterReading { await gate.wait() }
		return value
	}
}
