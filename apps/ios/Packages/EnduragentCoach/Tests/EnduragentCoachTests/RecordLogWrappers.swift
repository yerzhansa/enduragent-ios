import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

protocol ChainForwardingLog: ReviewChainLog {
	var chainStore: any ReviewChainLog { get }
}

extension ChainForwardingLog {
	func newest(_ query: RecordQuery) async throws -> NewestRecord {
		try await chainStore.newest(query)
	}

	func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
	{
		try await chainStore.append(record, after: head, in: query)
	}

	func chats(holding scope: RecordQuery.Scope) async throws -> Set<ChatID> {
		try await chainStore.chats(holding: scope)
	}

	func erase(_ locality: RecordLocality, sparing kept: DeviceID?) async throws -> Int {
		try await chainStore.erase(locality, sparing: kept)
	}

	func confirmSyncedExport(after saved: Date) async throws -> Bool {
		try await chainStore.confirmSyncedExport(after: saved)
	}
}

final class BatchRecordingLog: ChainForwardingLog, @unchecked Sendable {
	var chainStore: any ReviewChainLog { inner }
	let inner: any ReviewChainLog
	private(set) var batches: [[String]] = []
	private let scopes = Mutex<[RecordQuery.Scope]>([])
	private let cursorLocalities = Mutex<[RecordLocality]>([])
	private let recordCounts = Mutex(0)
	private let fetched = Mutex<[(query: RecordQuery, ulids: [ULID])]>([])

	var fetchedRecordCount: Int { recordCounts.withLock { $0 } }

	var reads: [RecordQuery.Scope] { scopes.withLock { $0 } }
	var cursorReads: [RecordLocality] { cursorLocalities.withLock { $0 } }
	var fetches: [(query: RecordQuery, ulids: [ULID])] { fetched.withLock { $0 } }

	init(inner: any ReviewChainLog) {
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
		fetched.withLock { $0.append((query, page.records.map(\.ulid))) }
		recordCounts.withLock { $0 += page.records.count + page.skipped.count }
		return page
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class HeldConversationReadLog: ChainForwardingLog, Sendable {
	var chainStore: any ReviewChainLog { inner }
	let inner: any ReviewChainLog
	let gate = Gate()
	var reached: AsyncStream<Void> { gate.reached }
	private let held = Mutex(false)

	init(inner: any ReviewChainLog) {
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

final class HeldAppendLog: ChainForwardingLog, Sendable {
	var chainStore: any ReviewChainLog { inner }
	let inner: any ReviewChainLog
	let kind: String
	let occurrence: Int
	private let gate = Gate()
	var reached: AsyncStream<Void> { gate.reached }
	private let seen = Mutex(0)

	init(inner: any ReviewChainLog, holding kind: String, occurrence: Int) {
		self.inner = inner
		self.kind = kind
		self.occurrence = occurrence
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		await holding(batch)
		try await inner.append(batch, locality: locality)
	}

	func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
	{
		await holding([record])
		try await inner.append(record, after: head, in: query)
	}

	private func holding(_ batch: [AthleteRecord]) async {
		let hold = seen.withLock { current -> Bool in
			guard batch.contains(where: { $0.body.kind == kind }) else { return false }
			current += 1
			return current == occurrence
		}
		if hold { await gate.wait() }
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

extension HeldAppendLog {
	func waitUntilReached() async throws {
		let parked = try await beforeDeadline(within: .hangGuard, onTimeout: release) {
			var arrivals = self.reached.makeAsyncIterator()
			return await arrivals.next() != nil
		}
		try #require(parked == true, "The held append was never reached")
	}
}
