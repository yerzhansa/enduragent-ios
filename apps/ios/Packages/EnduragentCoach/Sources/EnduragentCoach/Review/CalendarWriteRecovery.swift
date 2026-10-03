import Foundation

extension SingleProposalReviews {
	func recoverySnapshot(_ intent: CalendarWriteIntent, chat: ChatID) async throws(LedgerFailure)
		-> ReviewSnapshot?
	{
		let previous = deliveries[chat]?.ref
		let authority: ReviewAuthority =
			intent.record.deviceId == ledger.deviceId ? .thisDevice : .otherDevice
		let attribution = try await attribution(for: intent.record.account)
		let block = await accountBlock(intent.record.account)
		guard !closed.contains(intent.body.review) else { return nil }
		guard deliveries[chat]?.ref == previous else { return try await snapshot(chat: chat) }
		var delivery = delivery(set: intent.body.review, chat: chat, authority: authority)
		let cards = intent.proposal.map { [ReviewCard($0.body)] } ?? []
		let controls: ReviewControls
		if authority != .thisDevice || delivery.busy
			|| intent.proposal == nil
		{
			controls = .none
		} else if block == .accountChanged {
			let secret = delivery.secret ?? UUID()
			delivery.secret = secret
			deliveries[chat] = delivery
			controls = .cancelOnly(ReviewControlToken(ref: delivery.ref, secret: secret))
		} else if canRepeat(intent) {
			let secret = delivery.secret ?? UUID()
			delivery.secret = secret
			deliveries[chat] = delivery
			controls = .retryRemainingOrCancel(
				ReviewControlToken(ref: delivery.ref, secret: secret))
		} else {
			controls = .checkAgain(delivery.ref)
		}
		let notice = block.map(accountNotice) ?? pendingNotice(intent.body.evidence)
		return ReviewSnapshot(
			ref: delivery.ref,
			state: .available(
				ReviewContent(
					cards: cards, kept: [], totals: ReviewTotals(cards), receipts: [],
					notice: notice, authority: authority), controls), attribution: attribution)
	}

	func canRepeat(_ intent: CalendarWriteIntent) -> Bool {
		guard intent.body.writeID != nil, intent.cancellation == nil else { return false }
		switch (intent.body.target, intent.body.evidence) {
		case (.create, .unknown(.absent)), (.delete, .unknown(.found)): return true
		default: return false
		}
	}

	func recover(_ ref: ReviewRef, repeatWrite: Bool, scope: TurnScope?) async throws(LedgerFailure)
		-> ReviewOutcome
	{
		do {
			guard
				let intent = try await ledger.calendarWrites(ref.chat).first(where: {
					$0.body.review == ref.set
				}),
				intent.record.deviceId == ledger.deviceId, let live = intent.proposal,
				intent.body.evidence.dispatched, intent.cancellation == nil
			else { return unresolved(.unknown(.readFailed)) }
			if case .applied(let id?) = intent.body.evidence {
				return .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: String(id)))])
			}
			if await accountBlock(intent.record.account) == .accountChanged {
				return .blocked(.accountChanged)
			}
			let connection = try await training(true)
			guard Self.permits(intent.record.account.authority(under: connection.account)) else {
				return .blocked(.accountChanged)
			}
			if repeatWrite && !canRepeat(intent) { return unresolved(intent.body.evidence) }
			let evidence: CalendarWriteEvidence
			do {
				evidence = try await CalendarWriteOperation.observe(intent, on: connection.client)
			} catch { evidence = .unknown(.readFailed) }
			var observed = intent
			observed.body.evidence = intent.body.evidence.merging(evidence)
			if repeatWrite && canRepeat(observed) {
				let prepared = try await CalendarWriteOperation.prepare(
					live, client: connection.client,
					today: IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone))
				_ = try await record(intent, evidence: .unknown(.dispatched), scope: scope)
				return await dispatch(
					intent, operation: prepared, connection: connection, scope: scope)
			}
			return try await record(intent, evidence: evidence, scope: scope)
		} catch let error as LedgerFailure {
			if error == .unavailable { throw error }
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return unresolved(.unknown(.readFailed))
		} catch {
			return unresolved(.unknown(.readFailed))
		}
	}

	package func propose(
		chatId: ChatID, tool: GatedToolName, input: GatedToolInput, summary: String,
		description: String, scope: TurnScope
	) async throws -> PendingProposal {
		try await scope.proposing {
			try await self.registration.pass {
				let writes = try await self.ledger.calendarWrites(chatId)
				guard
					!writes.contains(where: {
						$0.blocksNewWork
					})
				else {
					throw IntervalsError(
						code: "calendar_write_pending",
						details:
							"Check the existing approved calendar write before proposing another change."
					)
				}
				return try await ProposalPolicy.save(
					chatId: chatId, tool: tool, input: input, summary: summary,
					description: description, now: self.clock.now, ledger: self.ledger,
					stamp: scope.stamp,
					appliedWrites: Set(
						writes.filter { $0.body.evidence.applied || $0.cancellation != nil }
							.compactMap(\.body.writeID)))
			}
		}
	}
}
