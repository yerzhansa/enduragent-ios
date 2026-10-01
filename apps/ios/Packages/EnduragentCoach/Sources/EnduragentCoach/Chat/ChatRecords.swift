import Foundation

final class ChatRecords {
	private let chat: ChatID
	private let ledger: Ledger
	private let reviews: any WorkoutReviews
	private let clock: any Clock
	private(set) var conversation: Conversation
	private(set) var review: ReviewSnapshot?
	private(set) var jobs: [FlushJob] = []
	private var applied: [ULID: AthleteRecord] = [:]

	init(chat: ChatID, ledger: Ledger, clock: any Clock, reviews: any WorkoutReviews) {
		self.chat = chat
		self.ledger = ledger
		self.reviews = reviews
		self.clock = clock
		self.conversation = Conversation(chat: chat, segments: [])
	}

	func refresh(
		recoveryRecords: [AthleteRecord]? = nil,
		isolation: isolated (any Actor)? = #isolation
	) async throws(LedgerFailure) {
		let imported: [AthleteRecord]
		if let recoveryRecords {
			let synced = try await ledger.read(
				RecordQuery(scope: ConversationFold.syncedScope, chatId: chat)
			).records
			imported =
				synced
				+ recoveryRecords.filter {
					$0.chatId == chat && ConversationFold.localScope.admits($0.body)
				}
		} else {
			imported = try await ledger.conversationRecords(chat)
		}
		for record in imported { applied[record.ulid] = record }
		var folded = ConversationFold.fold(
			chat: chat, synced: Array(applied.values), device: ledger.deviceId)
		let jobs: [FlushJob]
		if let recoveryRecords {
			jobs =
				try await ledger.flushJobsByChat(in: [chat: folded], local: recoveryRecords)[chat]
				?? []
		} else {
			jobs = try await ledger.flushJobs(in: folded)
		}
		let review = try await reviews.snapshot(chat: chat)
		folded.apply(Array(applied.values), device: ledger.deviceId)
		conversation = folded
		self.review = review
		self.jobs = jobs
	}

	func refreshReview(isolation: isolated (any Actor)? = #isolation) async {
		do {
			try await refreshNotes()
			review = try await reviews.snapshot(chat: chat)
		} catch {
			switch error {
			case .unavailable, .rejectedBatch: review = nil
			}
		}
	}

	func refreshJobs(
		from flushes: FlushWork, isolation: isolated (any Actor)? = #isolation
	) async -> [FlushJobID] {
		jobs = await flushes.jobs(in: conversation)
		return FlushJob.outstanding(jobs, in: conversation).map(\.id)
	}

	func apply(_ committed: [AthleteRecord]) {
		for record in committed { applied[record.ulid] = record }
		conversation.apply(committed, device: ledger.deviceId)
	}

	func refreshNotes(isolation: isolated (any Actor)? = #isolation) async throws(LedgerFailure) {
		let notes = try await ledger.read(
			RecordQuery(scope: .synced([.reviewApplied]), chatId: chat))
		apply(notes.records)
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
		apply(records)
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
		if let record = conversation.settleInMemory(
			turn, attempt: attempt, settlement, ulid: ulid, now: clock.now, device: ledger.deviceId)
		{
			applied[record.ulid] = record
		}
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
			if let record = conversation.observeInMemory(
				turn, attempt: stamp.attempt, device: ledger.deviceId)
			{
				applied[record.ulid] = record
			}
			ledger.report(.replyObservedUnsaved(stamp.attempt, detail: "\(error)"))
		}
	}
}
