import Foundation

package actor Ledger {
	private let log: any RecordLog
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private var cursor: HybridLogicalClock?
	private var lastUlid: ULID?
	private var opened = false
	private var reportedSkips: [SkippedRow] = []

	package init(log: any RecordLog, clock: any Clock, diagnostics: DiagnosticsLog) {
		self.log = log
		self.clock = clock
		self.diagnostics = diagnostics
		self.cursor = nil
		self.lastUlid = nil
	}

	package nonisolated var deviceId: DeviceID {
		log.deviceId
	}

	private func openIfNeeded() async throws(LedgerFailure) {
		if opened {
			return
		}
		let synced = try await fetch(RecordQuery(scope: .everySynced, writtenBy: deviceId))
		let local = try await fetch(RecordQuery(scope: .everyDeviceLocal, writtenBy: deviceId))
		for record in synced.records + local.records {
			fold(record.hlc)
			if lastUlid.map({ $0 < record.ulid }) ?? true {
				lastUlid = record.ulid
			}
		}
		opened = true
	}

	package func commit(synced bodies: [SyncedRecordBody], stamp: OperationStamp)
		async throws(LedgerFailure) -> [AthleteRecord]
	{
		try await append(bodies.map(RecordBody.synced), locality: .synced, stamp: stamp)
	}

	package func commit(local bodies: [DeviceLocalRecordBody], stamp: OperationStamp)
		async throws(LedgerFailure) -> [AthleteRecord]
	{
		try await append(bodies.map(RecordBody.deviceLocal), locality: .deviceLocal, stamp: stamp)
	}

	package func nextULID() -> ULID {
		let generated = ULID.generate(at: clock.now)
		let next: ULID
		if let lastUlid, generated <= lastUlid {
			next = lastUlid.incremented()
		} else {
			next = generated
		}
		lastUlid = next
		return next
	}

	package func read(_ query: RecordQuery) async throws(LedgerFailure) -> RecordPage {
		try await openIfNeeded()
		return try await fetch(query)
	}

	private func fetch(_ query: RecordQuery) async throws(LedgerFailure) -> RecordPage {
		let page: RecordPage
		do {
			page = try await log.fetch(query)
		} catch {
			throw LedgerFailure.unavailable
		}
		for record in page.records {
			fold(record.hlc)
		}
		for skipped in page.skipped where !reportedSkips.contains(skipped) {
			reportedSkips.append(skipped)
			diagnostics.record(.skippedRecord(skipped))
		}
		return page
	}

	package nonisolated var imports: AsyncStream<Void> {
		log.imports
	}

	private func append(_ bodies: [RecordBody], locality: RecordLocality, stamp: OperationStamp)
		async throws(LedgerFailure) -> [AthleteRecord]
	{
		try await openIfNeeded()
		let zone = stamp.binding.zone
		let civilDate = CivilDate(date: clock.now, timeZone: zone.timeZone)
		let records = bodies.map { body in
			AthleteRecord(
				ulid: nextULID(),
				deviceId: deviceId,
				hlc: nextClock(),
				timeZone: zone,
				civilDate: civilDate,
				cause: .operation(stamp.operation, stamp.attempt),
				account: stamp.binding.account,
				body: body
			)
		}
		do {
			try await log.append(records, locality: locality)
		} catch {
			throw LedgerFailure.rejectedBatch
		}
		return records
	}

	private func nextClock() -> HybridLogicalClock {
		let next = HybridLogicalClock.tick(now: clock.now, deviceId: deviceId, last: cursor)
		cursor = next
		return next
	}

	private func fold(_ seen: HybridLogicalClock) {
		guard let cursor else {
			self.cursor = seen
			return
		}
		if cursor < seen {
			self.cursor = seen
		}
	}
}

package enum LedgerFailure: Error, Sendable, Equatable {
	case unavailable
	case rejectedBatch
}
