import Foundation

final class ChatRecords {
	private let chat: ChatID
	private let ledger: Ledger
	private let reviews: any WorkoutReviews
	private let clock: any Clock
	private(set) var conversation: Conversation
	private(set) var review: ReviewSnapshot?
	private(set) var jobs: [FlushJob] = []
	private var loaded = false
	private var loading: Task<Result<Void, LedgerFailure>, Never>?
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

	func load(isolation: isolated (any Actor)? = #isolation) async throws(LedgerFailure) {
		guard !loaded else { return }
		if let loading {
			try await loading.value.get()
		} else {
			try await refresh()
		}
	}

	func refresh(isolation: isolated (any Actor)? = #isolation) async throws(LedgerFailure) {
		if let loading { try await loading.value.get() }
		let reading = Task {
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
			let imported = try await ledger.conversationRecords(chat)
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
			let jobs = try await ledger.flushJobs(in: folded)
			let review = try await reviews.snapshot(chat: chat)
			folded.apply(Array(applied.values), device: ledger.deviceId)
			conversation = folded
			self.review = review
			self.jobs = jobs
			loaded = true
			return .success(())
		} catch {
			return .failure(error)
		}
	}

	func refreshReview(
		_ ref: ReviewRef? = nil, isolation: isolated (any Actor)? = #isolation
	) async -> ReviewOutcome {
		if let ref, review?.ref != ref { return .staleControl }
		do {
			try await refreshNotes()
			review = try await reviews.snapshot(chat: chat)
			return .presentationRecorded
		} catch {
			reviewUnavailable(error)
			return .storageUnavailable
		}
	}

	private func reviewUnavailable(_ failure: LedgerFailure) {
		if let previous = review {
			review = ReviewSnapshot(
				ref: previous.ref, cards: previous.cards, kept: previous.kept,
				totals: previous.totals, receipts: previous.receipts,
				notice: ReviewNotice(
					kind: .storageUnavailable, key: Catalog.reviewStorageUnavailable, vars: [:]),
				controls: .none, authority: previous.authority)
		}
		ledger.report(.reviewUnavailable(chat, failure))
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

	func settle(
		_ settled: TurnSettledBody?, stamp: OperationStamp,
		isolation: isolated (any Actor)? = #isolation
	) async {
		guard let settled else { return }
		await retrySettlements()
		let record = await ledger.prepare(.synced(.turnSettled(settled)), stamp: stamp)
		await saveSettlement(record)
	}

	func retrySettlements(isolation: isolated (any Actor)? = #isolation) async {
		for record in pendingSettlements.values.sorted(by: { $0.ulid < $1.ulid }) {
			await saveSettlement(record)
		}
	}

	private func saveSettlement(
		_ record: AthleteRecord, isolation: isolated (any Actor)? = #isolation
	) async {
		guard case .synced(.turnSettled(let body)) = record.body else { return }
		do {
			try await ledger.commit(record)
			pendingSettlements[record.ulid] = nil
			apply([record])
		} catch {
			pendingSettlements[record.ulid] = record
			apply([record])
			ledger.report(.settlementUnsaved(body.turn, error))
			do {
				try await ledger.commit(
					record.replacingBody(.deviceLocal(.pendingSettlement(body))))
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
