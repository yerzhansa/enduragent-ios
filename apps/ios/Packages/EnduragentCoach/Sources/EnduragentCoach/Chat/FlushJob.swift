import Foundation

package struct FlushJob: Sendable, Equatable {
	package let id: FlushJobID
	package let origin: Origin
	package let coverage: Coverage
	package fileprivate(set) var phase: Phase = .pending
	package let reset: ResetID?

	package enum Origin: Sendable, Equatable {
		case process(ProcessID)
		case beforeUpgrade
	}

	package enum Phase: Sendable, Equatable {
		case pending
		case settled(Settlement)
		case superseded(FlushJobID)
	}

	package enum Settlement: Sendable, Equatable {
		case recorded(FlushSettlement)
		case consumedBeforeUpgrade
	}

	package struct Coverage: Sendable, Equatable {
		package let listed: [ULID]
		package let resolved: Set<ULID>
		package let legacy: Legacy?

		package enum Legacy: Sendable, Equatable {
			case before(ULID)
			case through(ULID)
		}
	}

	package var saved: Bool {
		switch phase {
		case .pending, .settled(.recorded(.abandoned)): false
		case .settled, .superseded: true
		}
	}

	package func covers(_ older: FlushJob) -> Bool {
		older.id.ulid < id.ulid && older.coverage.resolved.isSubset(of: coverage.resolved)
	}

	package static func outstanding(_ jobs: [FlushJob], in conversation: Conversation) -> [FlushJob]
	{
		ConversationRows(conversation).outstanding(jobs)
	}
}

package enum FlushOutcome: Sendable, Equatable {
	case saved(sections: Int, events: Int)
	case partial(sections: Int, events: Int, failure: CoachFailure)
	case failed(CoachFailure)
	case nothingToSave
}

package enum FlushGate {
	package static let softThresholdRatio = 0.8
	package static let cooldownMessages = 5

	package static func shouldQueueSoftFlush(
		estimatedHistoryTokens: Int, historyBudget: Int, messagesSinceLastFlush: Int
	) -> Bool {
		guard messagesSinceLastFlush >= cooldownMessages else { return false }
		return Double(estimatedHistoryTokens) > Double(historyBudget) * softThresholdRatio
	}
}

extension ConversationFold {
	package static let flushScope: RecordQuery.Scope = .deviceLocal([.flushPending, .flushSettled])
	package static let consumedMarkerScope: RecordQuery.Scope = .synced([.provenance])

	static func flushJobs(
		chat: ChatID, local: [AthleteRecord], markers: [AthleteRecord], device: DeviceID,
		rows: ConversationRows
	) -> [FlushJob] {
		let owned = local.filter { $0.chatId == chat && $0.deviceId == device }
			.sorted { $0.hlc < $1.hlc }
		let consumed = consumedJobs(markers)
		var settlements: [FlushJobID: FlushSettlement] = [:]
		for record in owned {
			if case .deviceLocal(.flushSettled(let body)) = record.body,
				settlements[body.job] != .abandoned
			{
				settlements[body.job] = body.settlement
			}
		}
		let jobs = owned.compactMap { record -> FlushJob? in
			guard case .deviceLocal(.flushPending(let body)) = record.body else { return nil }
			let id = FlushJobID(ulid: record.ulid)
			let origin = body.process.map(FlushJob.Origin.process) ?? .beforeUpgrade
			let consumedInV1 = origin == .beforeUpgrade && consumed.contains(id)
			let job = FlushJob(
				id: id, origin: origin,
				coverage: rows.coverage(
					for: id, messages: body.messageUlids, origin: origin, consumed: consumedInV1),
				reset: resetOpened(by: record.cause))
			if let settlement = settlements[id] {
				return FlushWork.transition(job, after: .settled(.recorded(settlement)))
			}
			return consumedInV1
				? FlushWork.transition(job, after: .settled(.consumedBeforeUpgrade)) : job
		}
		let done = jobs.filter { $0.phase != .pending }
		return jobs.map { job in
			guard let newer = done.first(where: { $0.covers(job) }) else { return job }
			return FlushWork.transition(job, after: .superseded(newer.id))
		}
	}

	private static func resetOpened(by cause: RecordCause) -> ResetID? {
		guard case .operation(.conversationReset(let reset), _) = cause else { return nil }
		return reset
	}

	private static func consumedJobs(_ markers: [AthleteRecord]) -> Set<FlushJobID> {
		let prefix = MemoryFlushPolicy.consumedFlushKeyPrefix
		var consumed: Set<FlushJobID> = []
		for record in markers {
			guard case .synced(.provenance(let body)) = record.body, body.key.hasPrefix(prefix),
				let ulid = ULID(rawValue: String(body.key.dropFirst(prefix.count)))
			else {
				continue
			}
			consumed.insert(FlushJobID(ulid: ulid))
		}
		return consumed
	}
}

private struct FlushedMessages {
	private var listed: Set<ULID> = []
	private var legacyThrough: ULID?
	private var legacyBefore: ULID?

	init(_ jobs: [FlushJob], in segment: SegmentID) {
		for job in jobs {
			listed.formUnion(job.coverage.listed)
			guard segment.boundary.map({ $0 <= job.id.ulid }) ?? true else { continue }
			switch job.coverage.legacy {
			case .before(let boundary):
				legacyBefore = max(legacyBefore ?? boundary, boundary)
			case .through(let boundary):
				legacyThrough = max(legacyThrough ?? boundary, boundary)
			case nil:
				break
			}
		}
	}

	func covers(_ ulid: ULID, legacy: Bool) -> Bool {
		listed.contains(ulid)
			|| (legacy
				&& (legacyThrough.map { ulid <= $0 } ?? false
					|| legacyBefore.map { ulid < $0 } ?? false))
	}
}

extension Conversation {
	package func messagesSinceLastFlush(
		_ jobs: [FlushJob], excluding turn: TurnID?, before boundary: HybridLogicalClock? = nil
	) -> [ConversationRow] {
		let segment = boundary.map { current.closing(at: $0) } ?? current
		let rows = segment.historyRows(excluding: turn, using: ownership)
		let coverage = FlushedMessages(jobs, in: segment.id)
		return rows.filter { row in
			return !coverage.covers(row.ulid, legacy: legacyMessageUlids.contains(row.ulid))
		}
	}

	package func flushMessages(for job: FlushJob) -> [ChatMessage] {
		flushRows(for: job).map(\.message)
	}

	package func flushRows(for job: FlushJob) -> [ConversationRow] {
		let rows = ConversationRows(self)
		return rows.messages(for: rows.ulids(for: job.id, messages: job.coverage.listed))
	}

	package func outstandingRows(_ jobs: [FlushJob]) -> [ConversationRow] {
		let rows = ConversationRows(self)
		let ulids = rows.outstanding(jobs).reduce(into: Set<ULID>()) {
			$0.formUnion($1.coverage.resolved)
		}
		return rows.messages(for: ulids.sorted())
	}

	package func messages(for ulids: [ULID]) -> [ChatMessage] {
		ConversationRows(self).messages(for: ulids).map(\.message)
	}
}

extension Ledger {
	package func flushJobs(in conversation: Conversation) async throws(LedgerFailure) -> [FlushJob]
	{
		let local = try await read(
			RecordQuery(
				scope: ConversationFold.flushScope, chatId: conversation.chat, writtenBy: deviceId)
		).records
		return try await flushJobsByChat(in: [conversation.chat: conversation], local: local)[
			conversation.chat] ?? []
	}

	package func flushJobsByChat(in conversations: [ChatID: Conversation], local: [AthleteRecord])
		async throws(LedgerFailure) -> [ChatID: [FlushJob]]
	{
		let rows = conversations.mapValues(ConversationRows.init)
		var jobs: [ChatID: [FlushJob]] = [:]
		for (chat, rows) in rows {
			jobs[chat] = ConversationFold.flushJobs(
				chat: chat, local: local, markers: [], device: deviceId, rows: rows)
		}
		let hasUnsettledV1Jobs = jobs.values.contains {
			$0.contains { $0.origin == .beforeUpgrade && $0.phase == .pending }
		}
		if hasUnsettledV1Jobs {
			let markers = try await read(RecordQuery(scope: ConversationFold.consumedMarkerScope))
				.records
			for (chat, rows) in rows {
				jobs[chat] = ConversationFold.flushJobs(
					chat: chat, local: local, markers: markers, device: deviceId, rows: rows)
			}
		}
		return jobs
	}
}

package struct FlushWork: Sendable {
	package let chat: ChatID
	package let process: ProcessID
	package let ledger: Ledger
	package let memory: Memory
	package let transport: any ModelTransport
	package let clock: any Clock
	package let diagnostics: DiagnosticsLog
	package let ladder: RetryLadder

	package func open(covering ulids: [ULID], stamp: OperationStamp)
		async throws(LedgerFailure) -> FlushJob
	{
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: chat, messageUlids: ulids, process: process))
			],
			stamp: stamp)
		guard let record = records.first else { throw LedgerFailure.rejectedBatch }
		return FlushJob(
			id: FlushJobID(ulid: record.ulid), origin: .process(process),
			coverage: .init(listed: ulids, resolved: Set(ulids), legacy: nil), reset: nil)
	}

	package func run(
		_ job: FlushJob, messages: [ChatMessage], access: ResolvedAccess, scope: TurnScope?
	) async throws(CancellationError) -> FlushOutcome {
		let stamp = await stamp(for: job)
		let outcome = try await extract(
			messages: messages, access: access, scope: scope, stamp: stamp)
		await settle(job, outcome, stamp: stamp)
		return outcome
	}

	package func stamp(for job: FlushJob) async -> OperationStamp {
		OperationStamp(
			operation: .memoryFlush(job.id),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
	}

	package func extract(
		messages: [ChatMessage], access: ResolvedAccess, scope: TurnScope?, stamp: OperationStamp
	) async throws(CancellationError) -> FlushOutcome {
		let outcome = try await memory.runFlush(
			messages: messages, access: access, transport: transport, diagnostics: diagnostics,
			ladder: ladder, stamp: stamp, scope: scope)
		switch outcome {
		case .partial, .failed:
			diagnostics.record(
				.memoryFlushFailed(chat, detail: "\(outcome)"),
				redacting: [access.credential.secret])
		case .saved, .nothingToSave:
			break
		}
		return outcome
	}

	package enum Transition {
		case settled(FlushJob.Settlement)
		case superseded(FlushJobID)
		case extracted(FlushOutcome, process: ProcessID)
	}

	package static func transition(_ job: FlushJob, after event: Transition) -> FlushJob {
		guard job.phase == .pending else { return job }
		var next = job
		switch event {
		case .settled(let settlement):
			next.phase = .settled(settlement)
		case .superseded(let newer):
			next.phase = .superseded(newer)
		case .extracted(let outcome, let process):
			switch outcome {
			case .saved(let sections, let events):
				next.phase = .settled(.recorded(.saved(sections: sections, events: events)))
			case .nothingToSave:
				next.phase = .settled(.recorded(.nothingToSave))
			case .failed(let failure), .partial(_, _, let failure):
				if job.origin != .process(process) && failure.abandonsFlush {
					next.phase = .settled(.recorded(.abandoned))
				}
			}
		}
		return next
	}

	package func settle(_ job: FlushJob, _ outcome: FlushOutcome, stamp: OperationStamp) async {
		let next = Self.transition(job, after: .extracted(outcome, process: process))
		guard job.phase == .pending, case .settled(.recorded(let settlement)) = next.phase else {
			return
		}
		do {
			_ = try await ledger.commit(
				local: [
					.flushSettled(
						FlushSettledBody(chatId: chat, job: job.id, settlement: settlement))
				],
				stamp: stamp)
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
		}
	}

	package func jobs(in conversation: Conversation) async -> Result<[FlushJob], LedgerFailure> {
		do {
			return .success(try await ledger.flushJobs(in: conversation))
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
			return .failure(error)
		}
	}

	package func drain(
		_ id: FlushJobID, in conversation: Conversation,
		access: () async throws(AccessUnavailable) -> ResolvedAccess
	) async {
		do {
			guard
				let job = try await ledger.flushJobs(in: conversation).first(where: { $0.id == id }
				),
				job.phase == .pending
			else {
				return
			}
			_ = try await run(
				job, messages: conversation.flushMessages(for: job), access: try await access(),
				scope: nil)
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
		}
	}
}
