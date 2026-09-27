import Foundation

package struct FlushJob: Sendable, Equatable {
	package let id: FlushJobID
	package let trigger: FlushTrigger
	package let messages: [ULID]
	package var process: ProcessID?
	package var settled: Bool
	package var reset: ResetID?
	package var abandoned = false
	package var consumedInV1 = false

	package var saved: Bool {
		settled && !abandoned
	}

	package func covers(_ older: FlushJob) -> Bool {
		guard older.id.ulid < id.ulid else { return false }
		guard !older.messages.isEmpty else { return true }
		return Set(older.messages).isSubset(of: Set(messages))
	}

	package static func outstanding(_ jobs: [FlushJob]) -> [FlushJob] {
		let pending = jobs.filter { !$0.settled }
		return pending.filter { job in !pending.contains { $0.covers(job) } }
	}
}

package enum FlushOutcome: Sendable, Equatable {
	case saved(sections: Int, events: Int)
	case partial(sections: Int, events: Int, failure: CoachFailure)
	case failed(CoachFailure)
	case nothingToSave

	package var settlement: FlushSettlement? {
		switch self {
		case .saved(let sections, let events):
			.saved(sections: sections, events: events)
		case .nothingToSave:
			.nothingToSave
		case .partial, .failed:
			nil
		}
	}
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

	package static func flushJobs(
		chat: ChatID, local: [AthleteRecord], markers: [AthleteRecord], device: DeviceID
	) -> [FlushJob] {
		let owned = local.filter { $0.chatId == chat && $0.deviceId == device }
			.sorted { $0.hlc < $1.hlc }
		let consumed = consumedJobs(markers)
		var settled: Set<FlushJobID> = []
		var abandoned: Set<FlushJobID> = []
		for record in owned {
			if case .deviceLocal(.flushSettled(let body)) = record.body {
				settled.insert(body.job)
				if body.settlement == .abandoned { abandoned.insert(body.job) }
			}
		}
		var jobs = owned.compactMap { record -> FlushJob? in
			guard case .deviceLocal(.flushPending(let body)) = record.body else { return nil }
			let id = FlushJobID(ulid: record.ulid)
			let consumedInV1 = body.process == nil && consumed.contains(id)
			return FlushJob(
				id: id, trigger: body.trigger, messages: body.messageUlids, process: body.process,
				settled: consumedInV1 || settled.contains(id), reset: resetOpened(by: record.cause),
				abandoned: abandoned.contains(id), consumedInV1: consumedInV1)
		}
		let done = jobs.filter(\.settled)
		for index in jobs.indices where !jobs[index].settled {
			jobs[index].settled = done.contains { $0.covers(jobs[index]) }
		}
		return jobs
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

private struct FlushCoverage {
	private var listed: Set<ULID> = []
	private var legacyThrough: ULID?
	private var legacyBefore: ULID?

	init(_ jobs: [FlushJob], in segment: SegmentID) {
		for job in jobs {
			listed.formUnion(job.messages)
			if job.process == nil {
				guard segment.boundary.map({ $0 <= job.id.ulid }) ?? true else { continue }
				if job.messages.isEmpty {
					legacyBefore = max(legacyBefore ?? job.id.ulid, job.id.ulid)
				} else if job.consumedInV1, let through = job.messages.max() {
					legacyThrough = max(legacyThrough ?? through, through)
				}
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
		_ jobs: [FlushJob], excluding turn: TurnID?, before boundary: ULID? = nil
	) -> [(ulid: ULID, message: ChatMessage)] {
		let segment = boundary.map { current.closing(at: $0) } ?? current
		let history = segment.promptHistory(excluding: turn)
		let coverage = FlushCoverage(jobs, in: segment.id)
		return zip(history.ulids, history.messages).compactMap { ulid, message in
			if coverage.covers(ulid, legacy: legacyMessageUlids.contains(ulid)) {
				return nil
			}
			return (ulid, message)
		}
	}

	package func flushMessages(for job: FlushJob) -> [ChatMessage] {
		flushRows(for: job).map(\.message)
	}

	package func flushRows(for job: FlushJob) -> [(ulid: ULID, message: ChatMessage)] {
		guard job.messages.isEmpty else { return rows(for: job.messages) }
		let segment = segments.last { $0.id.boundary.map { $0 <= job.id.ulid } ?? true }
		return (segment?.turns ?? []).flatMap(\.messageRows).filter { $0.ulid < job.id.ulid }
	}

	package func outstandingRows(_ jobs: [FlushJob]) -> [(ulid: ULID, message: ChatMessage)] {
		var byUlid: [ULID: ChatMessage] = [:]
		for job in FlushJob.outstanding(jobs) {
			for (ulid, message) in flushRows(for: job) {
				byUlid[ulid] = message
			}
		}
		return byUlid.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
	}

	package func messages(for ulids: [ULID]) -> [ChatMessage] {
		rows(for: ulids).map(\.message)
	}

	private func rows(for ulids: [ULID]) -> [(ulid: ULID, message: ChatMessage)] {
		var byUlid: [ULID: ChatMessage] = [:]
		for segment in segments {
			for turn in segment.turns {
				for (ulid, message) in [turn.userRow, turn.replyRow].compactMap({ $0 }) {
					byUlid[ulid] = message
				}
			}
		}
		return ulids.compactMap { ulid in byUlid[ulid].map { (ulid, $0) } }
	}
}

extension Ledger {
	package func flushJobs(in chat: ChatID) async throws(LedgerFailure) -> [FlushJob] {
		try await flushJobs(
			RecordQuery(scope: ConversationFold.flushScope, chatId: chat, writtenBy: deviceId)
		)[chat] ?? []
	}

	package func flushJobsByChat() async throws(LedgerFailure) -> [ChatID: [FlushJob]] {
		try await flushJobs(RecordQuery(scope: ConversationFold.flushScope, writtenBy: deviceId))
	}

	private func flushJobs(_ query: RecordQuery) async throws(LedgerFailure) -> [ChatID: [FlushJob]]
	{
		let local = try await read(query).records
		let chats = Set(local.compactMap(\.chatId))
		let hasUnsettledV1Jobs = chats.contains { chat in
			ConversationFold.flushJobs(chat: chat, local: local, markers: [], device: deviceId)
				.contains { $0.process == nil && !$0.settled }
		}
		var markers: [AthleteRecord] = []
		if hasUnsettledV1Jobs {
			markers = try await read(RecordQuery(scope: ConversationFold.consumedMarkerScope))
				.records
		}
		var jobs: [ChatID: [FlushJob]] = [:]
		for chat in chats {
			jobs[chat] = ConversationFold.flushJobs(
				chat: chat, local: local, markers: markers, device: deviceId)
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

	package func open(_ trigger: FlushTrigger, covering ulids: [ULID], stamp: OperationStamp)
		async throws(LedgerFailure) -> FlushJob
	{
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: chat, trigger: trigger, messageUlids: ulids, process: process))
			],
			stamp: stamp)
		guard let record = records.first else { throw LedgerFailure.rejectedBatch }
		return FlushJob(
			id: FlushJobID(ulid: record.ulid), trigger: trigger, messages: ulids, process: process,
			settled: false)
	}

	package func run(
		_ job: FlushJob, messages: [ChatMessage], access: ResolvedAccess, scope: TurnScope?
	) async throws(CancellationError) -> FlushOutcome {
		let stamp = await stamp(for: job)
		let outcome = try await extract(
			job, messages: messages, access: access, scope: scope, stamp: stamp)
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
		_ job: FlushJob, messages: [ChatMessage], access: ResolvedAccess, scope: TurnScope?,
		stamp: OperationStamp
	) async throws(CancellationError) -> FlushOutcome {
		let outcome = try await memory.runFlush(
			job, messages: messages, access: access, transport: transport, stamp: stamp,
			scope: scope)
		if outcome.settlement == nil {
			diagnostics.record(
				.memoryFlushFailed(chat, detail: "\(outcome)"),
				redacting: [access.credential.secret])
		}
		return outcome
	}

	package func settle(_ job: FlushJob, _ outcome: FlushOutcome, stamp: OperationStamp) async {
		let settlement: FlushSettlement
		if let saved = outcome.settlement {
			settlement = saved
		} else {
			guard job.process != process else { return }
			settlement = .abandoned
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

	package func jobs() async -> [FlushJob] {
		do {
			return try await ledger.flushJobs(in: chat)
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
			return []
		}
	}

	package func drain(
		_ id: FlushJobID, in conversation: Conversation,
		access: () throws(AccessUnavailable) -> ResolvedAccess
	) async {
		do {
			guard let job = try await ledger.flushJobs(in: chat).first(where: { $0.id == id }),
				!job.settled
			else {
				return
			}
			_ = try await run(
				job, messages: conversation.flushMessages(for: job), access: try access(),
				scope: nil)
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
		}
	}
}
