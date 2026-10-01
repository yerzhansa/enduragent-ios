import Foundation

package actor SingleProposalReviews: WorkoutReviews {
	let ledger: Ledger
	let clock: any Clock
	let diagnostics: DiagnosticsLog
	let training: @Sendable () async throws(AccessUnavailable) -> TrainingConnection
	let registration = Turnstile()
	var deliveries: [ChatID: ReviewDelivery] = [:]
	var closed: Set<ChangeSetID> = []

	package init(
		ledger: Ledger, clock: any Clock, diagnostics: DiagnosticsLog,
		training: @escaping @Sendable () async throws(AccessUnavailable) -> TrainingConnection
	) {
		self.ledger = ledger
		self.clock = clock
		self.diagnostics = diagnostics
		self.training = training
	}

	package func isExecuting(in chat: ChatID) -> Bool {
		deliveries[chat]?.busy == true
	}

	package func snapshot(chat: ChatID, records: [AthleteRecord]? = nil) async throws(LedgerFailure)
		-> ReviewSnapshot?
	{
		let previous = deliveries[chat]?.ref
		let intents = try await ledger.calendarWrites(chat, synced: records)
		guard deliveries[chat]?.ref == previous else { return try await snapshot(chat: chat) }
		if let intent = intents.first(where: {
			$0.body.evidence.dispatched && !$0.body.evidence.applied
				&& !closed.contains($0.body.review)
		}) {
			return try await recoverySnapshot(intent, chat: chat)
		}
		guard
			let live = try await ProposalPolicy.live(chatId: chat, ledger: ledger, now: clock.now),
			!closed.contains(ChangeSetID(ulid: live.ulid)),
			!intents.contains(where: {
				$0.body.review.ulid == live.ulid && $0.body.evidence.applied
			})
		else {
			deliveries[chat] = nil
			return nil
		}
		let block = await accountBlock(live.account)
		guard deliveries[chat]?.ref == previous else { return try await snapshot(chat: chat) }
		let delivery = delivery(
			set: ChangeSetID(ulid: live.ulid), chat: chat,
			authority: live.cause == .legacy ? .readOnly : .thisDevice)
		let card = ReviewCard(live.body)
		return ReviewSnapshot(
			ref: delivery.ref, cards: [card], kept: [], totals: ReviewTotals([card]), receipts: [],
			notice: delivery.authority == .readOnly
				? AthleteNotices.earlierVersion
				: block == .accountChanged ? AthleteNotices.accountChanged : nil,
			controls: block == .accountChanged ? .none : delivery.controls,
			authority: delivery.authority)
	}

	package func decide(
		_ decision: ReviewDecision, chat: ChatID, scope: TurnScope?,
		changed: @escaping @Sendable () async -> Void = {}
	) async
		-> ReviewOutcome
	{
		guard decision.ref.chat == chat, var delivery = deliveries[chat],
			delivery.ref == decision.ref
		else { return .staleControl }
		switch decision {
		case .presented:
			if delivery.authority == .thisDevice { delivery.secret = delivery.secret ?? UUID() }
		case .presentationFailed:
			delivery.secret = nil
		case .showAgain:
			guard !delivery.busy else { return .staleControl }
			delivery.ref = ReviewRef(
				chat: chat, set: delivery.ref.set, revision: delivery.ref.revision, delivery: UUID()
			)
			delivery.secret = nil
		case .approve(let token), .cancel(let token), .retryRemaining(let token):
			guard !delivery.busy, delivery.secret == token.secret else { return .staleControl }
			delivery.busy = true
			deliveries[chat] = delivery
			await changed()
			let outcome: ReviewOutcome
			switch decision {
			case .approve: outcome = await approve(token, scope: scope, changed: changed)
			case .retryRemaining:
				outcome = await recover(token.ref, repeatWrite: true, scope: scope)
			default: outcome = await cancel(token)
			}
			finish(token.ref, outcome: outcome)
			return outcome
		case .checkAgain(let ref):
			guard !delivery.busy else { return .staleControl }
			delivery.busy = true
			deliveries[chat] = delivery
			let outcome = await recover(ref, repeatWrite: false, scope: scope)
			finish(ref, outcome: outcome)
			return outcome
		}
		deliveries[chat] = delivery
		return .presentationRecorded
	}

	private func approve(
		_ token: ReviewControlToken, scope: TurnScope?,
		changed: @escaping @Sendable () async -> Void
	) async -> ReviewOutcome {
		if let scope {
			return await scope.reviewing {
				await self.applyApproval(token, scope: scope, changed: changed)
			}
		}
		return await applyApproval(token, scope: nil, changed: changed)
	}

	private func applyApproval(
		_ token: ReviewControlToken, scope: TurnScope?,
		changed: @escaping @Sendable () async -> Void
	) async
		-> ReviewOutcome
	{
		let prepared = await registration.pass { await prepareApproval(token, scope: scope) }
		switch prepared {
		case .refused(let outcome): return outcome
		case .ready(let intent, let operation, let connection):
			await changed()
			return await dispatch(
				intent, operation: operation, connection: connection, scope: scope)
		}
	}

	private func prepareApproval(_ token: ReviewControlToken, scope: TurnScope?) async
		-> PreparedCalendarApproval
	{
		do {
			guard
				let live = try await ProposalPolicy.live(
					chatId: token.ref.chat, ledger: ledger, now: clock.now),
				live.ulid == token.ref.set.ulid, live.cause != .legacy,
				live.body.writeID != nil
			else { return .refused(.staleControl) }
			let intents = try await ledger.calendarWrites(token.ref.chat)
			guard
				!intents.contains(where: {
					$0.body.review == token.ref.set && $0.body.evidence.dispatched
				})
			else { return .refused(.staleControl) }
			let connection = try await training()
			guard Self.permits(live.account.authority(under: connection.account)) else {
				return .refused(.blocked(.accountChanged))
			}
			let operation = try await CalendarWriteOperation.prepare(
				live, client: connection.client,
				today: IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone))
			if let scope, !(await scope.beginReview()) {
				return .refused(.blocked(.turnStopping))
			}
			guard case .operation(let origin, let attempt) = live.cause else {
				return .refused(.staleControl)
			}
			let stamp = OperationStamp(
				operation: origin, attempt: attempt,
				binding: ActionBinding(
					account: live.account, zone: AthleteCalendar(clock: clock).deviceZone))
			var body = ReviewWriteBody(
				chatId: live.body.chatId, review: token.ref.set, writeID: live.body.writeID,
				target: operation.target, evidence: .notSent)
			let records = try await ledger.commit(synced: [.reviewWrite(body)], stamp: stamp)
			guard let record = records.first else { return .refused(.storageUnavailable) }
			body.evidence = .unknown(.dispatched)
			_ = try await ledger.commit(synced: [.reviewWrite(body)], stamp: stamp)
			await scope?.recordReview(live, evidence: body.evidence)
			try await ProposalPolicy.clear(live, reason: .executed, ledger: ledger, stamp: stamp)
			return .ready(
				CalendarWriteIntent(record: record, body: body, proposal: live), operation,
				connection)
		} catch let error as LedgerFailure {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return .refused(.storageUnavailable)
		} catch {
			return .refused(.blocked(.cannotVerify))
		}
	}

	func dispatch(
		_ intent: CalendarWriteIntent, operation: CalendarWriteOperation,
		connection: TrainingConnection, scope: TurnScope?
	) async -> ReviewOutcome {
		do {
			let id = try await operation.dispatch(on: connection.client)
			return try await record(intent, evidence: .applied(eventID: id), scope: scope)
		} catch let error as LedgerFailure {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return unresolved(intent.body.evidence)
		} catch {
			if let stamp = intent.stamp, let proposal = intent.proposal {
				diagnostics.record(
					.toolFailed(
						stamp.attempt, proposal.body.tool.toolName, failure: ToolFault(error)))
			}
			return unresolved(intent.body.evidence)
		}
	}

	func record(_ intent: CalendarWriteIntent, evidence: CalendarWriteEvidence, scope: TurnScope?)
		async throws(LedgerFailure) -> ReviewOutcome
	{
		guard let stamp = intent.stamp else { throw .rejectedBatch }
		var body = intent.body
		body.evidence = body.evidence.merging(evidence)
		var bodies: [SyncedRecordBody] = [.reviewWrite(body)]
		if body.evidence.applied, let proposal = intent.proposal {
			bodies.append(
				.reviewApplied(
					ReviewAppliedBody(
						chatId: body.chatId, summary: ReviewSummary(proposal.body.toolInput))))
		}
		_ = try await ledger.commit(synced: bodies, stamp: stamp)
		if let proposal = intent.proposal {
			await scope?.recordReview(proposal, evidence: body.evidence)
		}
		if case .applied(let id?) = body.evidence {
			return .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: String(id)))])
		}
		return unresolved(body.evidence)
	}

	private func cancel(_ token: ReviewControlToken) async -> ReviewOutcome {
		do {
			let writes = try await ledger.calendarWrites(token.ref.chat)
			if let intent = writes.first(where: {
				$0.body.review == token.ref.set && $0.body.evidence.dispatched
			}) {
				guard canRepeat(intent), let live = intent.proposal, let stamp = intent.stamp else {
					return unresolved(intent.body.evidence)
				}
				do {
					try await ProposalPolicy.clear(
						live, reason: .canceled, ledger: ledger, stamp: stamp)
				} catch {
					diagnostics.record(.reviewOutcomeUnsaved(error))
				}
				return unresolved(intent.body.evidence)
			}
			guard
				let live = try await ProposalPolicy.live(
					chatId: token.ref.chat, ledger: ledger, now: clock.now),
				live.ulid == token.ref.set.ulid
			else { return .staleControl }
			let stamp = OperationStamp(
				operation: .workoutChangeSet(token.ref.set, token.ref.revision),
				attempt: AttemptID(ulid: await ledger.nextULID()),
				binding: ActionBinding(
					account: live.account, zone: AthleteCalendar(clock: clock).deviceZone))
			try await ProposalPolicy.clear(live, reason: .canceled, ledger: ledger, stamp: stamp)
			return .canceled(kept: [])
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return unresolved(.unknown(.readFailed))
		}
	}

	func finish(_ ref: ReviewRef, outcome: ReviewOutcome) {
		if case .applied = outcome { closed.insert(ref.set) }
		if case .canceled = outcome { closed.insert(ref.set) }
		if closed.contains(ref.set), deliveries[ref.chat]?.ref == ref { deliveries[ref.chat] = nil }
		if deliveries[ref.chat]?.ref == ref { deliveries[ref.chat]?.busy = false }
	}

	func delivery(set: ChangeSetID, chat: ChatID, authority: ReviewAuthority) -> ReviewDelivery {
		if let existing = deliveries[chat], existing.ref.set == set { return existing }
		let minted = ReviewDelivery(
			authority: authority,
			ref: ReviewRef(
				chat: chat, set: set, revision: ChangeSetRevision(rawValue: 1), delivery: UUID()))
		deliveries[chat] = minted
		return minted
	}

	static func permits(_ authority: AccountAuthority) -> Bool {
		switch authority {
		case .same, .sameAthlete: true
		case .changed, .unverifiable: false
		}
	}

	func accountBlock(_ account: TrainingAccount) async -> ReviewBlock? {
		do {
			return Self.permits(account.authority(under: try await training().account))
				? nil : .accountChanged
		} catch { return .cannotVerify }
	}

	func accountNotice(_ block: ReviewBlock) -> ReviewNotice {
		if block == .accountChanged { return AthleteNotices.accountChanged }
		return ReviewNotice(kind: .partialFailure, key: Catalog.reviewWriteReadFailed, vars: [:])
	}

	func unresolved(_ evidence: CalendarWriteEvidence) -> ReviewOutcome {
		.uncertain(pendingNotice(evidence))
	}

	func pendingNotice(_ evidence: CalendarWriteEvidence) -> ReviewNotice {
		ReviewNotice(
			kind: .partialFailure,
			key: evidence == .unknown(.readFailed)
				? Catalog.reviewWriteReadFailed : Catalog.reviewWritePending,
			vars: [:])
	}
}

struct ReviewDelivery {
	let authority: ReviewAuthority
	var ref: ReviewRef
	var secret: UUID?
	var busy = false

	var controls: ReviewControls {
		guard authority == .thisDevice, !busy, let secret else { return .none }
		return .approveOrCancel(ReviewControlToken(ref: ref, secret: secret))
	}
}

enum PreparedCalendarApproval {
	case refused(ReviewOutcome)
	case ready(CalendarWriteIntent, CalendarWriteOperation, TrainingConnection)
}
