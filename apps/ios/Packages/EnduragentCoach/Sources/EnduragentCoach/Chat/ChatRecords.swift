import Foundation

final class ChatRecords {
	private let chat: ChatID
	private let ledger: Ledger
	private let clock: any Clock
	private(set) var conversation: Conversation
	var pendingProposal: PendingProposal?
	private(set) var jobs: [FlushJob] = []
	private var loaded = false
	private var loading: Task<Result<Void, LedgerFailure>, Never>?

	init(chat: ChatID, ledger: Ledger, clock: any Clock) {
		self.chat = chat
		self.ledger = ledger
		self.clock = clock
		self.conversation = Conversation(chat: chat, segments: [])
	}

	func load(isolation: isolated (any Actor)? = #isolation) async throws(LedgerFailure) {
		guard !loaded else { return }
		let reading =
			loading
			?? Task {
				_ = isolation
				return await self.read()
			}
		loading = reading
		try await reading.value.get()
	}

	private func read(isolation: isolated (any Actor)? = #isolation) async
		-> Result<Void, LedgerFailure>
	{
		defer { loading = nil }
		do {
			let folded = try await ledger.conversation(chat)
			pendingProposal = try await ProposalPolicy.pending(chat, from: ledger, at: clock.now)
			jobs = try await ledger.flushJobs(in: chat)
			conversation = folded
			loaded = true
			return .success(())
		} catch {
			return .failure(error)
		}
	}

	func refreshProposal(isolation: isolated (any Actor)? = #isolation) async {
		do {
			pendingProposal = try await ProposalPolicy.pending(chat, from: ledger, at: clock.now)
		} catch {
			pendingProposal = nil
		}
	}

	func refreshJobs(
		from flushes: FlushWork, isolation: isolated (any Actor)? = #isolation
	) async -> [FlushJobID] {
		jobs = await flushes.jobs()
		return FlushJob.outstanding(jobs).map(\.id)
	}

	func apply(_ committed: [AthleteRecord]) {
		conversation = ConversationFold.applying(
			committed, to: conversation, device: ledger.deviceId)
	}

	func writes(_ event: TurnEvent, for turn: TurnID) -> Result<TurnWrites, TurnRefusal> {
		TurnLifecycle.writes(
			for: event, on: conversation.turn(turn), chat: chat, device: ledger.deviceId,
			mint: { turn })
	}

	func commit(
		_ writes: TurnWrites, stamp: OperationStamp, isolation: isolated (any Actor)? = #isolation
	) async throws(LedgerFailure) {
		let records = try await ledger.commit(writes, stamp: stamp)
		conversation = ConversationFold.applying(records, to: conversation, device: ledger.deviceId)
	}

	func settle(
		_ turn: TurnID, _ event: TurnEvent, stamp: OperationStamp,
		isolation: isolated (any Actor)? = #isolation
	) async {
		guard case .success(let planned) = writes(event, for: turn),
			case .synced(let bodies) = planned, case .turnSettled(let settled)? = bodies.first
		else {
			return
		}
		do {
			try await commit(planned, stamp: stamp)
		} catch {
			await settleUnsaved(turn, attempt: settled.attempt, settled.settlement)
		}
	}

	func settleUnsaved(
		_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement,
		isolation: isolated (any Actor)? = #isolation
	) async {
		let ulid = await ledger.nextULID()
		conversation.settleInMemory(
			turn, attempt: attempt, settlement, ulid: ulid, now: clock.now, zone: clock.timeZone,
			device: ledger.deviceId)
	}

	func observeReply(
		_ turn: TurnID, stamp: OperationStamp, isolation: isolated (any Actor)? = #isolation
	) async {
		guard case .success(let mark) = writes(.observeReply(stamp.attempt), for: turn) else {
			return
		}
		do {
			try await commit(mark, stamp: stamp)
		} catch {
			conversation.observeInMemory(turn, attempt: stamp.attempt)
			ledger.report(.replyObservedUnsaved(stamp.attempt, detail: "\(error)"))
		}
	}
}
