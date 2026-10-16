import Foundation

package struct FlushWork: Sendable {
	package let chat: ChatID
	package let process: ProcessID
	package let ledger: Ledger
	package let memory: Memory
	package let transport: any ModelTransport
	package let clock: any Clock
	package let diagnostics: DiagnosticsLog
	package let ladder: RetryLadder

	package func open(covering rows: [ConversationRow], stamp: OperationStamp)
		async throws(LedgerFailure) -> [FlushJob]
	{
		let ownership = try await ledger.informationOwnership()
		let sources = OwnedFlushRows.partition(
			rows, using: ownership, jobDevice: ledger.deviceId, zone: stamp.binding.zone)
		var jobs: [FlushJob] = []
		for source in sources { jobs.append(try await open(source: source, stamp: stamp)) }
		return jobs
	}

	private func open(source: OwnedFlushRows, stamp: OperationStamp) async throws(LedgerFailure)
		-> FlushJob
	{
		let ulids = source.rows.map(\.ulid)
		let records = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: chat, messageUlids: ulids, sourceBound: true, process: process))
			],
			stamp: OperationStamp(
				operation: stamp.operation, attempt: stamp.attempt, binding: source.binding))
		guard let record = records.first else { throw LedgerFailure.rejectedBatch }
		return FlushJob(
			id: FlushJobID(ulid: record.ulid), origin: .process(process),
			coverage: .init(listed: ulids, resolved: Set(ulids), legacy: nil),
			source: .bound(source.binding), reset: nil)
	}

	package func run(
		_ job: FlushJob, rows: [ConversationRow], access: ResolvedAccess, scope: TurnScope?
	) async throws(CancellationError) -> FlushOutcome {
		do {
			switch job.source {
			case .bound:
				let stamp = await stamp(for: job)
				let outcome = try await extract(
					messages: rows.filter { job.coverage.resolved.contains($0.ulid) }.map(
						\.message), access: access, scope: scope, stamp: stamp)
				await settle(job, outcome, stamp: stamp)
				return outcome
			case .recoverFromRows:
				let ownership = try await ledger.informationOwnership()
				let sources = OwnedFlushRows.partition(
					rows, using: ownership, jobDevice: ledger.deviceId,
					zone: AthleteCalendar(clock: clock).deviceZone)
				if sources.count <= 1 {
					var bound = job
					bound.source = .bound(
						sources.first?.binding
							?? ownership.sourceBinding(
								for: .unconnected, jobDevice: ledger.deviceId,
								zone: AthleteCalendar(clock: clock).deviceZone))
					return try await run(bound, rows: rows, access: access, scope: scope)
				}
				return try await recover(job, sources: sources, access: access, scope: scope)
			}
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
			return .failed(.local(.recordStorage))
		}
	}

	private func recover(
		_ job: FlushJob, sources: [OwnedFlushRows], access: ResolvedAccess, scope: TurnScope?
	) async throws -> FlushOutcome {
		let conversation = try await ledger.conversation(chat)
		let jobs = try await ledger.flushJobs(in: conversation)
		let parentStamp = await stamp(for: job)
		var outcomes: [FlushOutcome] = []
		var children: Set<FlushJobID> = []
		for source in sources {
			let ulids = Set(source.rows.map(\.ulid))
			let child: FlushJob
			if let existing = jobs.last(where: {
				$0.source.sharesOwner(with: .bound(source.binding))
					&& ulids.isSubset(of: $0.coverage.resolved)
			}) {
				child = existing
			} else {
				child = try await open(source: source, stamp: parentStamp)
			}
			children.insert(child.id)
			if child.saved {
				outcomes.append(.nothingToSave)
			} else {
				outcomes.append(
					try await run(child, rows: source.rows, access: access, scope: scope))
			}
		}
		let outcome = FlushOutcome.combining(outcomes)
		switch outcome {
		case .saved, .nothingToSave:
			let refreshed = try await ledger.flushJobs(in: conversation)
			if children.allSatisfy({ id in refreshed.contains { $0.id == id && $0.saved } }) {
				await settle(job, outcome, stamp: parentStamp)
			}
		case .partial, .failed: break
		}
		return outcome
	}

	package func stamp(for job: FlushJob) async -> OperationStamp {
		let binding: ActionBinding
		if case .bound(let source) = job.source {
			binding = source
		} else {
			binding = ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		}
		return OperationStamp(
			operation: .memoryFlush(job.id), attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: binding)
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
				job, rows: conversation.flushRows(for: job), access: try await access(),
				scope: nil)
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: "\(error)"))
		}
	}
}
