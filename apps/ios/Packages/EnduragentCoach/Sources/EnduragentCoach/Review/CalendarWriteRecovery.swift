import Foundation

extension SingleProposalReviews {
	func recoverySnapshot(_ intent: CalendarWriteIntent, chat: ChatID) async throws(LedgerFailure)
		-> ReviewSnapshot?
	{
		let previous = deliveries[chat]?.ref
		let authority: ReviewAuthority =
			intent.record.deviceId == ledger.deviceId ? .thisDevice : .otherDevice
		let block = await accountBlock(intent.record.account)
		guard !closed.contains(intent.body.review) else { return nil }
		guard deliveries[chat]?.ref == previous else { return try await snapshot(chat: chat) }
		var delivery = delivery(set: intent.body.review, chat: chat, authority: authority)
		let cards = intent.proposal.map { [ReviewCard($0.body)] } ?? []
		let controls: ReviewControls
		if authority != .thisDevice || block == .accountChanged || delivery.busy
			|| intent.proposal == nil
		{
			controls = .none
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
			ref: delivery.ref, cards: cards, kept: [], totals: ReviewTotals(cards), receipts: [],
			notice: notice, controls: controls, authority: authority)
	}

	func canRepeat(_ intent: CalendarWriteIntent) -> Bool {
		guard intent.body.writeID != nil, !intent.canceled else { return false }
		switch (intent.body.target, intent.body.evidence) {
		case (.create, .unknown(.absent)), (.delete, .unknown(.found)): return true
		default: return false
		}
	}

	func recover(_ ref: ReviewRef, repeatWrite: Bool, scope: TurnScope?) async -> ReviewOutcome {
		do {
			guard
				let intent = try await ledger.calendarWrites(ref.chat).first(where: {
					$0.body.review == ref.set
				}),
				intent.record.deviceId == ledger.deviceId, let live = intent.proposal,
				intent.body.evidence.dispatched
			else { return unresolved(.unknown(.readFailed)) }
			if case .applied(let id?) = intent.body.evidence {
				return .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: String(id)))])
			}
			let connection = try await training()
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
						$0.body.evidence.dispatched && !$0.body.evidence.applied
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
						writes.filter { $0.body.evidence.applied }.compactMap(\.body.writeID)))
			}
		}
	}
}
