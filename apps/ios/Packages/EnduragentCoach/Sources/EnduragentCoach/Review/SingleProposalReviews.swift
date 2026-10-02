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

	package func decide(
		_ decision: ReviewDecision, chat: ChatID, scope: TurnScope?,
		changed: @escaping @Sendable () async throws(LedgerFailure) -> Void = {}
	) async throws(LedgerFailure)
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
			defer { finish(token.ref, outcome: .presentationRecorded) }
			switch decision {
			case .cancel: break
			default: try await changed()
			}
			let outcome: ReviewOutcome
			switch decision {
			case .approve: outcome = try await approve(token, scope: scope, changed: changed)
			case .retryRemaining:
				outcome = try await recover(token.ref, repeatWrite: true, scope: scope)
			default: outcome = try await cancel(token)
			}
			finish(token.ref, outcome: outcome)
			return outcome
		case .checkAgain(let ref):
			guard !delivery.busy else { return .staleControl }
			delivery.busy = true
			deliveries[chat] = delivery
			defer { finish(ref, outcome: .presentationRecorded) }
			let outcome = try await recover(ref, repeatWrite: false, scope: scope)
			finish(ref, outcome: outcome)
			return outcome
		}
		deliveries[chat] = delivery
		return .presentationRecorded
	}

	private func approve(
		_ token: ReviewControlToken, scope: TurnScope?,
		changed: @escaping @Sendable () async throws(LedgerFailure) -> Void
	) async throws(LedgerFailure) -> ReviewOutcome {
		if let scope {
			return try await scope.reviewing { () throws(LedgerFailure) in
				try await self.applyApproval(token, scope: scope, changed: changed)
			}
		}
		return try await applyApproval(token, scope: nil, changed: changed)
	}

	private func applyApproval(
		_ token: ReviewControlToken, scope: TurnScope?,
		changed: @escaping @Sendable () async throws(LedgerFailure) -> Void
	) async throws(LedgerFailure)
		-> ReviewOutcome
	{
		let prepared = try await registration.pass { () throws(LedgerFailure) in
			try await prepareApproval(token, scope: scope)
		}
		switch prepared {
		case .refused(let outcome): return outcome
		case .ready(let intent, let operation, let connection):
			try await changed()
			return await dispatch(
				intent, operation: operation, connection: connection, scope: scope)
		}
	}

	private func prepareApproval(_ token: ReviewControlToken, scope: TurnScope?)
		async throws(LedgerFailure)
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
			guard connection.account != .unconnected else {
				return .refused(.blocked(.trainingNotConnected))
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
			if error == .unavailable { throw error }
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

	private func cancel(_ token: ReviewControlToken) async throws(LedgerFailure) -> ReviewOutcome {
		try await registration.pass { () throws(LedgerFailure) in
			do throws(LedgerFailure) {
				let writes = try await ledger.calendarWrites(token.ref.chat)
				if let intent = writes.first(where: { $0.body.review == token.ref.set }) {
					guard intent.blocksNewWork, let stamp = intent.stamp else {
						return .staleControl
					}
					let body = try ReviewCancelledUnknownBody.cancelling(
						intent, on: ledger.deviceId)
					_ = try await ledger.commit(
						synced: [.reviewCancelledUnknown(body)], stamp: stamp)
					return .canceled(kept: [])
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
				try await ProposalPolicy.clear(
					live, reason: .canceled, ledger: ledger, stamp: stamp)
				return .canceled(kept: [])
			} catch {
				if error == .unavailable { throw error }
				diagnostics.record(.reviewOutcomeUnsaved(error))
				return .storageUnavailable
			}
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

enum PreparedCalendarApproval {
	case refused(ReviewOutcome)
	case ready(CalendarWriteIntent, CalendarWriteOperation, TrainingConnection)
}
