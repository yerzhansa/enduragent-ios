import Foundation

package actor Ledger {
	enum CommitMode {
		case initial
		case retry
	}

	package static let reportedSkipLimit = DiagnosticsLog.capacity / 2

	private let log: any RecordLog
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private var cursor: HybridLogicalClock?
	private var lastUlid: ULID?
	private var opened = false
	private var reportedSkips: Set<SkippedRow> = []
	private let preparedCommits = Turnstile()

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

	package nonisolated func report(_ unsaved: DiagnosticsEvent) {
		diagnostics.record(unsaved)
	}

	private func openIfNeeded() async throws(LedgerFailure) {
		if opened {
			return
		}
		do {
			for locality in [RecordLocality.synced, .deviceLocal] {
				guard let head = try await log.latest(locality: locality, writtenBy: deviceId)
				else {
					continue
				}
				report(head.skipped)
				if let hlc = head.hlc { fold(hlc) }
				if let ulid = head.ulid, lastUlid.map({ $0 < ulid }) ?? true {
					lastUlid = ulid
				}
			}
		} catch {
			throw LedgerFailure.unavailable
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
		report(page.skipped)
		return page
	}

	private func report(_ rows: [SkippedRow]) {
		for skipped in rows where reportedSkips.count < Self.reportedSkipLimit {
			if reportedSkips.insert(skipped).inserted {
				diagnostics.record(.skippedRecord(skipped))
			}
		}
	}

	package nonisolated var imports: AsyncStream<Void> {
		log.imports
	}

	private func append(_ bodies: [RecordBody], locality: RecordLocality, stamp: OperationStamp)
		async throws(LedgerFailure) -> [AthleteRecord]
	{
		try await openIfNeeded()
		let records = bodies.map { prepare($0, stamp: stamp) }
		try await append(records, locality: locality)
		return records
	}

	func prepare(_ body: RecordBody, stamp: OperationStamp) -> AthleteRecord {
		AthleteRecord(
			ulid: nextULID(), deviceId: deviceId, hlc: nextClock(),
			timeZone: stamp.binding.zone,
			civilDate: CivilDate(date: clock.now, timeZone: stamp.binding.zone.timeZone),
			cause: .operation(stamp.operation, stamp.attempt), account: stamp.binding.account,
			body: body)
	}

	func commit(_ record: AthleteRecord, mode: CommitMode) async throws(LedgerFailure) {
		try await preparedCommits.pass { () throws(LedgerFailure) in
			if case .retry = mode {
				let scope: RecordQuery.Scope
				switch record.body {
				case .synced(let body): scope = .synced([body.kind])
				case .deviceLocal(let body): scope = .deviceLocal([body.kind])
				case .legacy: throw LedgerFailure.rejectedBatch
				}
				let saved = try await read(
					RecordQuery(scope: scope, chatId: record.chatId, turn: record.body.turn))
				guard !saved.records.contains(where: { $0.ulid == record.ulid }) else { return }
			}
			try await append([record], locality: record.locality)
		}
	}

	private func append(_ records: [AthleteRecord], locality: RecordLocality)
		async throws(LedgerFailure)
	{
		do {
			try await log.append(records, locality: locality)
		} catch {
			throw LedgerFailure.rejectedBatch
		}
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
