import Foundation

package actor WorkoutReviewDesk {
	let ledger: Ledger
	let clock: any Clock
	let diagnostics: DiagnosticsLog
	let training: @Sendable (Bool) async throws(AccessUnavailable) -> TrainingConnection
	let host: any ExecutionHost
	let effects = Turnstile()
	private var preparations: [DraftKey: Preparing] = [:]
	private var marked: Set<DraftKey> = []
	var deliveries: [ChatID: Delivery] = [:]
	var stalled: Set<ChatID> = []
	package nonisolated let changes: AsyncStream<ChatID>
	private let changed: AsyncStream<ChatID>.Continuation

	package init(
		ledger: Ledger, clock: any Clock, diagnostics: DiagnosticsLog,
		training: @escaping @Sendable (Bool) async throws(AccessUnavailable) -> TrainingConnection,
		host: any ExecutionHost
	) {
		self.ledger = ledger
		self.clock = clock
		self.diagnostics = diagnostics
		self.training = training
		self.host = host
		(changes, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
	}

	package func prepare(
		_ request: Result<PreparationRequest, ToolInputError>, for key: DraftKey, chat: ChatID,
		binding: ActionBinding, reads: any CalendarReads
	) async -> PreparationReply {
		if preparations[key] == .refused(.concurrentPreparation) {
			return .refused(.concurrentPreparation)
		}
		let parsed: PreparationRequest
		switch request {
		case .failure(let error):
			preparations[key] = .refused(.unreadableRequest(error))
			return .refused(.unreadableRequest(error))
		case .success(let request):
			parsed = request
		}
		preparations[key] = .reading
		if !marked.contains(key) {
			do throws(LedgerFailure) {
				try await ledger.markPreparing(
					chat: chat, turn: key.turn, attempt: key.attempt,
					stamp: OperationStamp(
						operation: .turn(key.turn), attempt: key.attempt, binding: binding))
				marked.insert(key)
			} catch {
				diagnostics.record(.reviewOutcomeUnsaved(error))
				return refusing(.storageUnavailable, for: key)
			}
		}
		let head: (RecordHead, WorkoutReview?)
		do throws(LedgerFailure) {
			head = try await ledger.reviewHead(chat: chat)
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return refusing(.storageUnavailable, for: key)
		}
		do throws(PreparationRefusal) {
			let draft = try await Preparation.draft(
				parsed, key: key, chat: chat, binding: binding, head: head.1, reads: reads,
				today: IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone))
			let reply: PreparationReply =
				switch draft.content {
				case .incomplete: .incomplete
				case .changes(let remaining, _):
					.drafted(changes: remaining.count, base: draft.base)
				}
			preparations[key] = .drafted(draft, over: head.0)
			return reply
		} catch {
			return refusing(error, for: key)
		}
	}

	package func refuseConcurrentPreparations(_ key: DraftKey) {
		preparations[key] = .refused(.concurrentPreparation)
	}

	package func abandonDraft(_ key: DraftKey) {
		guard preparations[key] != nil else { return }
		preparations[key] = .abandoned
	}

	package func settle(_ key: DraftKey, in chat: ChatID, ending: TurnEnding) async
		-> PreparationOutcome
	{
		let preparing = preparations.removeValue(forKey: key)
		marked.remove(key)
		switch (ending, preparing) {
		case (.processEnded, _):
			return await settleDeadClaim(key, in: chat)
		case (_, nil):
			return .none
		case (.abandoned, _), (_, .abandoned?):
			return .notPrepared(.turnDidNotFinish)
		case (.finished, .reading?):
			return .notPrepared(.incomplete)
		case (.finished, .refused?):
			return .notPrepared(.refused)
		case (.finished, .drafted(let draft, let head)?):
			return await commit(draft, over: head)
		}
	}

	package func decide(_ decision: ReviewDecision) async -> ReviewOutcome {
		switch decision {
		case .presented(let ref):
			return presenting(ref) { $0.acknowledge() }
		case .presentationFailed(let ref):
			return presenting(ref) { $0.disarmed() }
		case .showAgain(let ref):
			return presenting(ref) { $0.renewed() }
		case .approve(let token):
			return await effects.pass { await claiming(token, as: .approve) }
		case .tryAgain(let token):
			return await effects.pass { await claiming(token, as: .tryAgain) }
		case .cancel(let token):
			return await canceling(token)
		case .checkAgain(let token):
			return await effects.pass { await checkingAgain(token) }
		case .retryRemaining(let token):
			guard let delivery = deliveries[token.ref.chat], delivery.admits(token) else {
				return .staleControl(newer: deliveries[token.ref.chat]?.ref)
			}
			return .wrongAction
		case .checkAgainWithoutToken:
			return .wrongAction
		}
	}

	func publish(_ review: WorkoutReview, stamp: OperationStamp) async -> Bool {
		let ending: ReviewOutcomeBody.Ending =
			if case .canceled = review.stage { .canceled } else { .completed }
		do throws(LedgerFailure) {
			_ = try await ledger.commit(
				synced: [.reviewOutcome(ReviewProjection.summary(of: review, ending: ending))],
				stamp: stamp)
			moved(review.chat)
			return true
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return false
		}
	}

	package func snapshot(chat: ChatID) async throws(LedgerFailure) -> ReviewSnapshot? {
		let (head, review) = try await ledger.reviewHead(chat: chat)
		guard let review, case .record(let ulid) = head else { return nil }
		if try await isPublished(review) { return nil }
		let delivery =
			deliveries[chat].flatMap { $0.head == ulid ? $0 : nil }
			?? Delivery.fresh(for: review, at: ulid)
		deliveries[chat] = delivery
		let shown = ReviewProjection.snapshot(
			of: review, delivery: delivery,
			placement: ReviewProjection.placement(
				of: review, in: try await ledger.conversation(chat)),
			attribution: AthleteAttribution(
				accounts: [review.account], using: try await ledger.informationOwnership(),
				device: ledger.deviceId))
		return stalled.contains(chat) ? shown.disablingButtons() : shown
	}

	package func holdsBoundWork() async throws(LedgerFailure) -> Bool {
		let preparing = preparations.values.contains { preparation in
			switch preparation {
			case .reading, .drafted: true
			case .refused, .abandoned: false
			}
		}
		if preparing { return true }
		for chat in try await ledger.reviewChats() {
			switch try await ledger.reviewHead(chat: chat).1?.stage {
			case .waiting?, .running?: return true
			case .completed?, .canceled?, nil: continue
			}
		}
		return false
	}

	func isPublished(_ review: WorkoutReview) async throws(LedgerFailure) -> Bool {
		switch review.stage {
		case .completed, .canceled:
			try await ledger.reviewOutcomes(chat: review.chat)[review.id] != nil
		case .waiting, .running:
			false
		}
	}

	func moved(_ chat: ChatID) {
		stalled.remove(chat)
		changed.yield(chat)
	}

	func stall(_ chat: ChatID) -> ReviewOutcome {
		stalled.insert(chat)
		changed.yield(chat)
		return .storageUnavailable
	}

	package func pending(chat: ChatID) async throws(LedgerFailure) -> PendingReview {
		PendingReview(try await ledger.reviewHead(chat: chat).1)
	}

	private func refusing(_ refusal: PreparationRefusal, for key: DraftKey) -> PreparationReply {
		preparations[key] = .refused(refusal)
		return .refused(refusal)
	}

	private func commit(_ draft: ReviewDraft, over head: RecordHead) async -> PreparationOutcome {
		let current: (RecordHead, WorkoutReview?)
		do throws(LedgerFailure) {
			current = try await ledger.reviewHead(chat: draft.chat)
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return .notPrepared(.notSaved)
		}
		guard current.0 == head else { return .notPrepared(.refused) }
		let ledger = ledger
		guard
			let review = await draft.committed(
				over: draft.base == nil ? nil : current.1,
				id: WorkoutReviewID(ulid: await ledger.nextULID()),
				minting: { ChangeID(ulid: await ledger.nextULID()) })
		else { return .notPrepared(.incomplete) }
		do throws(TransitionFailure) {
			let record = try await ledger.commit(
				review: review,
				stamp: OperationStamp(
					operation: .turn(draft.key.turn), attempt: draft.key.attempt,
					binding: draft.binding),
				after: head)
			deliveries[draft.chat] = .fresh(for: review, at: record.ulid)
			moved(draft.chat)
			return .committed(ReviewBase(of: review))
		} catch {
			switch error {
			case .headMoved:
				return .notPrepared(.refused)
			case .storage(let failure):
				diagnostics.record(.reviewOutcomeUnsaved(failure))
				return .notPrepared(.notSaved)
			}
		}
	}

	private func settleDeadClaim(_ key: DraftKey, in chat: ChatID) async -> PreparationOutcome {
		do throws(LedgerFailure) {
			let markers = try await ledger.reviewPreparing(chat: chat, turn: key.turn)
			guard markers.contains(where: { $0.attempt == key.attempt }) else { return .none }
			guard let head = try await ledger.reviewHead(chat: chat).1, head.origin == key else {
				return .notPrepared(.processEnded)
			}
			return .committed(ReviewBase(of: head))
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return .none
		}
	}

	private func presenting(_ ref: ReviewRef, _ change: (Delivery) -> Delivery) -> ReviewOutcome {
		guard let delivery = deliveries[ref.chat], delivery.ref == ref else {
			return .staleControl(newer: deliveries[ref.chat]?.ref)
		}
		deliveries[ref.chat] = change(delivery)
		return .presentationRecorded
	}
}
