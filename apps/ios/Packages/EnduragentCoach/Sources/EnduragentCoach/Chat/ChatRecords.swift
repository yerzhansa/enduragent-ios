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
	private var pendingSettlements: [ULID: AthleteRecord] = [:]

	var unsavedTurns: Set<TurnID> {
		Set(pendingSettlements.values.compactMap { $0.body.turn })
	}

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
		try await readingReview { () throws(LedgerFailure) in
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
			let saved = Set(imported.filter { $0.locality == .synced }.map(\.ulid))
			for record in imported {
				if case .deviceLocal(.pendingSettlement(let body)) = record.body,
					record.deviceId == ledger.deviceId, !saved.contains(record.ulid)
				{
					pendingSettlements[record.ulid] = record.replacingBody(
						.synced(.turnSettled(body)))
				}
			}
			for record in imported { applied[record.ulid] = record }
			await retrySettlements()
			var folded = ConversationFold.fold(
				chat: chat, synced: Array(applied.values), device: ledger.deviceId)
			let jobs: [FlushJob]
			if let recoveryRecords {
				jobs =
					try await ledger.flushJobsByChat(in: [chat: folded], local: recoveryRecords)[
						chat]
					?? []
			} else {
				jobs = try await ledger.flushJobs(in: folded)
			}
			let snapshot = try await reviews.snapshot(chat: chat, records: imported)
			folded.apply(Array(applied.values), device: ledger.deviceId)
			conversation = folded
			self.jobs = jobs
			return ((), snapshot)
		}
	}

	func hasLocalWork(isolation: isolated (any Actor)? = #isolation) async -> Bool {
		let reviewing = await reviews.isExecuting(in: chat)
		return reviewing || conversation.hasLocalWork(on: ledger.deviceId)
	}

	func refreshReview(
		_ ref: ReviewRef? = nil, isolation: isolated (any Actor)? = #isolation
	) async -> ReviewOutcome {
		if let ref, review?.ref != ref { return .staleControl }
		do {
			try await updateReview()
			return .presentationRecorded
		} catch {
			return .storageUnavailable
		}
	}

	func decide(
		_ decision: ReviewDecision, scope: TurnScope?,
		changed: @escaping @Sendable () async throws(LedgerFailure) -> Void,
		isolation: isolated (any Actor)? = #isolation
	) async -> ReviewOutcome {
		var outcome = ReviewOutcome.storageUnavailable
		do {
			try await readingReview { () throws(LedgerFailure) in
				outcome = try await reviews.decide(
					decision, chat: chat, scope: scope, changed: changed)
				return (outcome, try await savedReview())
			}
		} catch {
			return outcome
		}
		return outcome
	}

	func updateReview(isolation: isolated (any Actor)? = #isolation) async throws(LedgerFailure) {
		try await readingReview { () throws(LedgerFailure) in
			return ((), try await savedReview())
		}
	}

	private func savedReview(isolation: isolated (any Actor)? = #isolation)
		async throws(LedgerFailure) -> ReviewSnapshot?
	{
		try await refreshNotes()
		return try await reviews.snapshot(chat: chat, records: nil)
	}

	private func readingReview<Value>(
		isolation: isolated (any Actor)? = #isolation,
		_ read: nonisolated(nonsending) () async throws(LedgerFailure) -> (Value, ReviewSnapshot?)
	) async throws(LedgerFailure) -> Value {
		let retained = review
		do {
			let (value, snapshot) = try await read()
			if case .cancelledUnknown? = snapshot?.state {
				review = nil
			} else {
				review = snapshot
			}
			return value
		} catch {
			review = (review?.ref == retained?.ref ? retained : review)?.disablingButtons()
			ledger.report(.reviewUnavailable(chat, error))
			throw error
		}
	}

	func refreshJobs(
		from flushes: FlushWork, isolation: isolated (any Actor)? = #isolation
	) async -> [FlushJobID] {
		switch await flushes.jobs(in: conversation) {
		case .success(let saved):
			jobs = saved
		case .failure:
			break
		}
		return FlushJob.outstanding(jobs, in: conversation).map(\.id)
	}

	func apply(_ committed: [AthleteRecord]) {
		for record in committed { applied[record.ulid] = record }
		conversation.apply(committed, device: ledger.deviceId)
	}

	func refreshNotes(isolation: isolated (any Actor)? = #isolation) async throws(LedgerFailure) {
		let notes = try await ledger.read(
			RecordQuery(
				scope: .synced([.reviewApplied, .reviewWrite, .reviewCancelledUnknown]),
				chatId: chat))
		apply(notes.records)
	}

	func settle(
		_ settled: TurnSettledBody?, stamp: OperationStamp,
		isolation: isolated (any Actor)? = #isolation
	) async {
		guard let settled else { return }
		await retrySettlements()
		let record = await ledger.prepare(.synced(.turnSettled(settled)), stamp: stamp)
		await saveSettlement(record, mode: .initial)
	}

	func retrySettlements(isolation: isolated (any Actor)? = #isolation) async {
		for record in pendingSettlements.values.sorted(by: { $0.ulid < $1.ulid }) {
			await saveSettlement(record, mode: .retry)
		}
	}

	func stopBeforeStart(
		_ turns: [TurnID], isolation: isolated (any Actor)? = #isolation
	) async {
		for turn in turns {
			let stamp = OperationStamp.turn(
				turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
			let stopped = TurnLifecycle.stopBeforeStart(
				stamp.attempt, on: conversation.turn(turn), chat: chat)
			guard case .success(let settled) = stopped else { continue }
			await settle(settled, stamp: stamp)
		}
	}

	func recover(_ claims: [DeadClaim], isolation: isolated (any Actor)? = #isolation) async {
		for dead in claims {
			let stamp = OperationStamp.turn(dead.turn, attempt: dead.attempt, clock: clock)
			await settle(
				TurnLifecycle.settled(
					dead.attempt,
					.interrupted(partial: "", cause: .processEnded, saved: dead.saved),
					on: conversation.turn(dead.turn), chat: chat), stamp: stamp)
		}
	}

	private func saveSettlement(
		_ record: AthleteRecord, mode: Ledger.CommitMode,
		isolation: isolated (any Actor)? = #isolation
	) async {
		guard case .synced(.turnSettled(let body)) = record.body else { return }
		do {
			try await ledger.commit(record, mode: mode)
			pendingSettlements[record.ulid] = nil
			apply([record])
		} catch {
			pendingSettlements[record.ulid] = record
			apply([record])
			ledger.report(.settlementUnsaved(body.turn, error))
			do {
				try await ledger.commit(
					record.replacingBody(.deviceLocal(.pendingSettlement(body))), mode: mode)
			} catch {
				ledger.report(.settlementUnsaved(body.turn, error))
			}
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
		guard
			let mark = TurnLifecycle.observeReply(
				stamp.attempt, on: conversation.turn(turn), chat: chat)
		else {
			return
		}
		do {
			apply(try await ledger.commit(local: [.replyObserved(mark)], stamp: stamp))
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
