import Foundation

package struct FlushJob: Sendable, Equatable {
	package let id: FlushJobID
	package let trigger: FlushTrigger
	package let messages: [ULID]
	package let settled: Bool

	package var coverage: ULID {
		messages.max() ?? id.ulid
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
		var settled = consumedJobs(markers)
		for record in owned {
			if case .deviceLocal(.flushSettled(let body)) = record.body {
				settled.insert(body.job)
			}
		}
		return owned.compactMap { record in
			guard case .deviceLocal(.flushPending(let body)) = record.body else { return nil }
			let id = FlushJobID(ulid: record.ulid)
			return FlushJob(
				id: id, trigger: body.trigger, messages: body.messageUlids,
				settled: settled.contains(id))
		}
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

extension Segment {
	package func messagesSinceLastFlush(_ jobs: [FlushJob], excluding turn: TurnID?)
		-> [(ulid: ULID, message: ChatMessage)]
	{
		let history = promptHistory(excluding: turn)
		let coverage = jobs.map(\.coverage).max()
		return zip(history.ulids, history.messages).compactMap { ulid, message in
			if let coverage, ulid <= coverage {
				return nil
			}
			return (ulid, message)
		}
	}
}

extension Conversation {
	package func flushMessages(for job: FlushJob) -> [ChatMessage] {
		guard job.messages.isEmpty else { return messages(for: job.messages) }
		let segment = segments.last { $0.id.boundary.map { $0 <= job.id.ulid } ?? true }
		return (segment?.turns ?? []).flatMap(\.messageRows)
			.filter { $0.ulid < job.id.ulid }
			.map(\.message)
	}

	package func messages(for ulids: [ULID]) -> [ChatMessage] {
		var byUlid: [ULID: ChatMessage] = [:]
		for segment in segments {
			for turn in segment.turns {
				for (ulid, message) in [turn.userRow, turn.replyRow].compactMap({ $0 }) {
					byUlid[ulid] = message
				}
			}
		}
		return ulids.compactMap { byUlid[$0] }
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
		let unsettledByRecord = chats.contains { chat in
			ConversationFold.flushJobs(chat: chat, local: local, markers: [], device: deviceId)
				.contains { !$0.settled }
		}
		var markers: [AthleteRecord] = []
		if unsettledByRecord {
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
				.flushPending(FlushPendingBody(chatId: chat, trigger: trigger, messageUlids: ulids))
			],
			stamp: stamp)
		guard let record = records.first else { throw LedgerFailure.rejectedBatch }
		return FlushJob(
			id: FlushJobID(ulid: record.ulid), trigger: trigger, messages: ulids, settled: false)
	}

	package func run(
		_ job: FlushJob, messages: [ChatMessage], access: ResolvedAccess, scope: TurnScope?
	) async throws(CancellationError) -> FlushOutcome {
		let stamp = OperationStamp(
			operation: .memoryFlush(job.id),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
		let outcome = try await memory.runFlush(
			job, messages: messages, access: access, transport: transport, stamp: stamp,
			scope: scope)
		guard let settlement = outcome.settlement else {
			diagnostics.record(
				.memoryFlushFailed(chat, detail: "\(outcome)"),
				redacting: [access.credential.secret])
			return outcome
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
		return outcome
	}

	package func pending() async -> [FlushJobID] {
		do {
			return try await ledger.flushJobs(in: chat).filter { !$0.settled }.map(\.id)
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
