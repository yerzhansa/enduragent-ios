import Foundation

package actor WorkoutReviewDesk {
	private let ledger: Ledger
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private var preparations: [DraftKey: Preparing] = [:]
	private var marked: Set<DraftKey> = []
	private var deliveries: [ChatID: Delivery] = [:]

	package init(ledger: Ledger, clock: any Clock, diagnostics: DiagnosticsLog) {
		self.ledger = ledger
		self.clock = clock
		self.diagnostics = diagnostics
	}

	package func prepare(
		_ request: Result<PreparationRequest, ToolInputError>, for key: DraftKey, chat: ChatID,
		binding: ActionBinding, reads: any CalendarReads
	) async -> PreparationReply {
		switch preparations[key] {
		case .reading?, .refused(.concurrentPreparation)?:
			preparations[key] = .refused(.concurrentPreparation)
			return .refused(.concurrentPreparation)
		case .drafted?, .refused?, .abandoned?, nil:
			break
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
			return finishing(key, as: .drafted(draft, over: head.0), replying: reply)
		} catch {
			return refusing(error, for: key)
		}
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

	package func decide(_ decision: ReviewDecision) -> ReviewOutcome {
		switch decision {
		case .presented(let ref):
			return presenting(ref) { $0.acknowledge() }
		case .presentationFailed(let ref):
			return presenting(ref) { $0.disarmed() }
		case .showAgain(let ref):
			return presenting(ref) { $0.renewed() }
		case .approve(let token), .retryRemaining(let token), .tryAgain(let token),
			.checkAgain(let token), .cancel(let token):
			guard let delivery = deliveries[token.ref.chat], delivery.admits(token) else {
				return .staleControl(newer: deliveries[token.ref.chat]?.ref)
			}
			return .wrongAction
		case .checkAgainWithoutToken:
			return .wrongAction
		}
	}

	package func snapshot(chat: ChatID) async throws(LedgerFailure) -> ReviewSnapshot? {
		let (head, review) = try await ledger.reviewHead(chat: chat)
		guard let review, case .record(let ulid) = head else { return nil }
		switch review.stage {
		case .completed, .canceled:
			if try await ledger.reviewOutcomes(chat: chat)[review.id] != nil { return nil }
		case .waiting, .running:
			break
		}
		let delivery =
			deliveries[chat].flatMap { $0.head == ulid ? $0 : nil }
			?? Delivery.fresh(for: review, at: ulid)
		deliveries[chat] = delivery
		return ReviewProjection.snapshot(
			of: review, delivery: delivery, placement: .afterTurn(review.origin.turn),
			attribution: AthleteAttribution(
				accounts: [review.account], using: try await ledger.informationOwnership(),
				device: ledger.deviceId))
	}

	package func pending(chat: ChatID) async throws(LedgerFailure) -> PendingReview {
		PendingReview(try await ledger.reviewHead(chat: chat).1)
	}

	private func refusing(_ refusal: PreparationRefusal, for key: DraftKey) -> PreparationReply {
		finishing(key, as: .refused(refusal), replying: .refused(refusal))
	}

	private func finishing(_ key: DraftKey, as state: Preparing, replying reply: PreparationReply)
		-> PreparationReply
	{
		switch preparations[key] {
		case .reading?:
			preparations[key] = state
			return reply
		case .refused(.concurrentPreparation)?:
			return .refused(.concurrentPreparation)
		case .drafted?, .refused?, .abandoned?, nil:
			return reply
		}
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
