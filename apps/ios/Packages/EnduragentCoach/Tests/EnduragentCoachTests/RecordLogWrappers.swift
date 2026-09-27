import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class BatchRecordingLog: RecordLog, @unchecked Sendable {
	let inner: any RecordLog
	private(set) var batches: [[String]] = []

	init(inner: any RecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		batches.append(batch.map(\.body.kind))
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class SlowAppendLog: RecordLog, Sendable {
	let inner: any RecordLog
	let delay: Duration

	init(inner: any RecordLog, delay: Duration) {
		self.inner = inner
		self.delay = delay
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await Task.sleep(for: delay)
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class SlowConversationReadLog: RecordLog, Sendable {
	let inner: any RecordLog
	let delay: Duration
	let fails: Bool
	let reached: AsyncStream<Void>
	private let reachedContinuation: AsyncStream<Void>.Continuation
	private let slowed = Mutex(false)

	init(inner: any RecordLog, delay: Duration, fails: Bool = false) {
		self.inner = inner
		self.delay = delay
		self.fails = fails
		(reached, reachedContinuation) = AsyncStream.makeStream()
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let page = try await inner.fetch(query)
		let slow = slowed.withLock { done -> Bool in
			guard !done, query.scope == ConversationFold.syncedScope else { return false }
			done = true
			return true
		}
		guard slow else { return page }
		reachedContinuation.yield()
		try await Task.sleep(for: delay)
		if fails {
			throw RecordStorageFault(operation: .fetch)
		}
		return page
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class HeldAppendLog: RecordLog, Sendable {
	let inner: any RecordLog
	let kind: String
	let occurrence: Int
	let reached: AsyncStream<Void>
	private let reachedContinuation: AsyncStream<Void>.Continuation
	private let state = Mutex<(seen: Int, held: CheckedContinuation<Void, Never>?)>((0, nil))

	init(inner: any RecordLog, holding kind: String, occurrence: Int) {
		self.inner = inner
		self.kind = kind
		self.occurrence = occurrence
		(reached, reachedContinuation) = AsyncStream.makeStream()
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let hold = state.withLock { current -> Bool in
			guard batch.contains(where: { $0.body.kind == kind }) else { return false }
			current.seen += 1
			return current.seen == occurrence
		}
		if hold {
			await withCheckedContinuation { continuation in
				state.withLock { $0.held = continuation }
				reachedContinuation.yield()
			}
		}
		try await inner.append(batch, locality: locality)
	}

	func release() {
		state.withLock { current in
			current.held?.resume()
			current.held = nil
		}
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class SlowScopeLog: RecordLog, Sendable {
	let inner: any RecordLog
	let scope: RecordQuery.Scope
	let delay: Duration

	init(inner: any RecordLog, scope: RecordQuery.Scope, delay: Duration) {
		self.inner = inner
		self.scope = scope
		self.delay = delay
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		if query.scope == scope {
			try await Task.sleep(for: delay)
		}
		return try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
