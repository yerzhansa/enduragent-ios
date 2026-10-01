import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class BatchRecordingLog: RecordLog, @unchecked Sendable {
	let inner: any RecordLog
	private(set) var batches: [[String]] = []
	private let scopes = Mutex<[RecordQuery.Scope]>([])
	private let cursorLocalities = Mutex<[RecordLocality]>([])
	private let recordCounts = Mutex(0)

	var fetchedRecordCount: Int { recordCounts.withLock { $0 } }

	var reads: [RecordQuery.Scope] { scopes.withLock { $0 } }
	var cursorReads: [RecordLocality] { cursorLocalities.withLock { $0 } }

	init(inner: any RecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		batches.append(batch.map(\.body.kind))
		try await inner.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		cursorLocalities.withLock { $0.append(locality) }
		return try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		scopes.withLock { $0.append(query.scope) }
		let page = try await inner.fetch(query)
		recordCounts.withLock { $0 += page.records.count + page.skipped.count }
		return page
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class HeldConversationReadLog: RecordLog, Sendable {
	let inner: any RecordLog
	let gate = Gate()
	var reached: AsyncStream<Void> { gate.reached }
	private let held = Mutex(false)

	init(inner: any RecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let page: Result<RecordPage, any Error>
		do {
			page = .success(try await inner.fetch(query))
		} catch {
			page = .failure(error)
		}
		let hold = held.withLock { done -> Bool in
			guard !done, query.scope == ConversationFold.syncedScope else { return false }
			done = true
			return true
		}
		guard hold else { return try page.get() }
		await gate.wait()
		return try page.get()
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class HeldAppendLog: RecordLog, Sendable {
	let inner: any RecordLog
	let kind: String
	let occurrence: Int
	private let gate = Gate()
	var reached: AsyncStream<Void> { gate.reached }
	private let seen = Mutex(0)

	init(inner: any RecordLog, holding kind: String, occurrence: Int) {
		self.inner = inner
		self.kind = kind
		self.occurrence = occurrence
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let hold = seen.withLock { current -> Bool in
			guard batch.contains(where: { $0.body.kind == kind }) else { return false }
			current += 1
			return current == occurrence
		}
		if hold { await gate.wait() }
		try await inner.append(batch, locality: locality)
	}

	func release() { gate.release() }

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
