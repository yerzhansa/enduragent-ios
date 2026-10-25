import Foundation

package actor Plans {
	static let lifetime: Duration = .seconds(600)
	static let settleAppendAttempts = 3
	static let tapAdmissions = 2

	private let ledger: Ledger
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private let currentAccount: @Sendable () async throws(AccessUnavailable) -> TrainingAccount
	private var preparations: [DraftKey: PlanPreparation] = [:]
	private var deliveries: [ChatID: PlanDelivery] = [:]
	private var stalled: Set<PlanConfirmationID> = []
	private var wakes: [ChatID: PlanWake] = [:]
	private let effects = Turnstile()
	nonisolated let changes: AsyncStream<ChatID>
	private let changed: AsyncStream<ChatID>.Continuation

	package init(
		ledger: Ledger, clock: any Clock, diagnostics: DiagnosticsLog,
		currentAccount: @escaping @Sendable () async throws(AccessUnavailable) -> TrainingAccount
	) {
		self.ledger = ledger
		self.clock = clock
		self.diagnostics = diagnostics
		self.currentAccount = currentAccount
		(changes, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
	}

	deinit {
		for wake in wakes.values {
			wake.task.cancel()
		}
	}

	fileprivate func prepare(_ arguments: JSONValue, for key: DraftKey, binding: ActionBinding)
		async throws -> ToolExecution
	{
		if preparations[key] == .refused {
			throw ToolInputError(
				code: "concurrent_plan_save",
				details: "Call plan_save once per step. Nothing was prepared.")
		}
		let document = try PlanDocument.parse(arguments: arguments)
		let ownership = try await ledger.informationOwnership()
		if case .unavailable = ownership.scope(for: binding.account, device: ledger.deviceId) {
			throw ToolInputError(
				code: "plan_unavailable",
				details:
					"Plans cannot be saved for this athlete on this device. Nothing was prepared."
			)
		}
		preparations[key] = .held(document, binding)
		return .result(
			.object([
				"pendingConfirmation": .bool(true), "summary": .string(document.pendingSummary),
			]))
	}

	func refuseConcurrentSaves(_ key: DraftKey) {
		preparations[key] = .refused
	}

	func settle(_ key: DraftKey, in chat: ChatID, ending: TurnEnding) async -> PlanSettlement {
		let preparing = preparations.removeValue(forKey: key)
		switch (ending, preparing) {
		case (.processEnded, _):
			return await settleDeadAttempt(key, in: chat)
		case (_, nil):
			return .nothingWaiting
		case (.abandoned, _):
			return .notPrepared(.turnDidNotFinish)
		case (.finished, .refused?):
			return .notPrepared(.refused)
		case (.finished, .held(let document, let binding)?):
			return await commit(document, for: key, in: chat, binding: binding)
		}
	}

	func snapshot(chat: ChatID) async throws(LedgerFailure) -> [PlanCard] {
		let chain = try await self.chain(of: chat)
		guard let newest = chain.newest else { return [] }
		let delivery =
			deliveries[chat].flatMap { $0.head == newest.newest.ulid ? $0 : nil }
			?? PlanDelivery.fresh(for: newest, chat: chat)
		deliveries[chat] = delivery
		if case .live = chain.phase(of: newest, at: clock.now) {
			wake(chat, at: newest.prepared.expiresAt)
		}
		return PlanCardProjection.cards(
			chain: chain,
			saved: try await Memory(ledger: ledger, clock: clock).savedPlans(
				for: newest.prepared.account),
			conversation: try await ledger.conversation(chat), delivery: delivery, stalled: stalled,
			at: clock.now)
	}

	func decide(_ decision: PlanDecision) async -> PlanDecisionOutcome {
		switch decision {
		case .presented(let ref):
			return presenting(ref)
		case .save(let token):
			let current: TrainingAccount
			do throws(AccessUnavailable) {
				current = try await currentAccount()
			} catch {
				return .storageUnavailable
			}
			return await tapping(token, as: .save(current: current))
		case .cancel(let token):
			return await tapping(token, as: .cancel)
		}
	}

	private func presenting(_ ref: PlanCardRef) -> PlanDecisionOutcome {
		guard var delivery = deliveries[ref.chat], delivery.ref == ref else {
			return .notSaved(.notPresented)
		}
		delivery.acknowledge()
		deliveries[ref.chat] = delivery
		changed.yield(ref.chat)
		return .presented
	}

	private func tapping(_ token: PlanSaveToken, as tap: PlanTap) async -> PlanDecisionOutcome {
		let chat = token.ref.chat
		for _ in 0..<Self.tapAdmissions {
			let live: LiveConfirmation
			do throws(LedgerFailure) {
				switch PlanAdmission.admit(
					token, as: tap, delivery: deliveries[chat], chain: try await chain(of: chat),
					at: clock.now)
				{
				case .failure(let refusal): return .notSaved(refusal)
				case .success(let admitted): live = admitted
				}
			} catch {
				diagnostics.record(.planConfirmationUnavailable(chat, error))
				return .storageUnavailable
			}
			let attempt = AttemptID(ulid: await ledger.nextULID())
			let step: PlanConfirmationStep
			switch tap {
			case .save:
				step = .claimed(
					PlanAdmission.claim(
						live, savedPlan: SavedPlanID(ulid: await ledger.nextULID()),
						attempt: attempt))
			case .cancel:
				step = .canceled
			}
			let record: AthleteRecord
			do throws(TransitionFailure) {
				record = try await append(
					step, of: live.confirmation, in: chat,
					stamp: live.confirmation.tapStamp(attempt: attempt, zone: zone),
					after: live.head)
			} catch {
				switch error {
				case .headMoved:
					continue
				case .storage(let failure):
					diagnostics.record(.planConfirmationUnavailable(chat, failure))
					return .storageUnavailable
				}
			}
			changed.yield(chat)
			guard case .save = tap else { return .canceled }
			guard let appended = PlanStepRecord(record),
				let claimed = PlanAdmission.claimed(live, appended: appended)
			else {
				stall(live.confirmation.id, in: chat, .unavailable)
				return .storageUnavailable
			}
			do throws(LedgerFailure) {
				try await effects.pass { () throws(LedgerFailure) in
					try await finish(claimed, in: chat)
				}
			} catch {
				stall(claimed.confirmation.id, in: chat, error)
				return .storageUnavailable
			}
			changed.yield(chat)
			return .saved
		}
		return .storageUnavailable
	}

	func recover() async {
		await effects.pass {
			do throws(LedgerFailure) {
				let chats = try await ledger.chats(holding: PlanChain.kind)
				for chat in chats.sorted(by: { $0.rawValue < $1.rawValue }) { await resume(chat) }
			} catch {
				diagnostics.record(.recoveryUnavailable(error))
			}
		}
	}

	private func resume(_ chat: ChatID) async {
		let chain: PlanChain
		do throws(LedgerFailure) {
			chain = try await self.chain(of: chat)
		} catch {
			diagnostics.record(.planConfirmationUnavailable(chat, error))
			return
		}
		for claimed in PlanAdmission.resumed(chain) {
			do throws(LedgerFailure) {
				try await finish(claimed, in: chat)
				stalled.remove(claimed.confirmation.id)
				changed.yield(chat)
			} catch {
				stall(claimed.confirmation.id, in: chat, error)
			}
		}
		if let newest = chain.newest, case .live = chain.phase(of: newest, at: clock.now) {
			wake(chat, at: newest.prepared.expiresAt)
		}
	}

	private func stall(
		_ confirmation: PlanConfirmationID, in chat: ChatID, _ failure: LedgerFailure
	) {
		stalled.insert(confirmation)
		diagnostics.record(.planSaveStalled(confirmation, failure))
		changed.yield(chat)
	}

	private func finish(_ claimed: ClaimedSave, in chat: ChatID) async throws(LedgerFailure) {
		let stamp = claimed.stamp(zone: zone)
		var wrote = false
		var moves = 0
		while moves < Self.settleAppendAttempts {
			let chain = try await self.chain(of: chat)
			guard
				let confirmation = chain.confirmations.first(where: {
					$0.id == claimed.confirmation.id
				})
			else { throw .unavailable }
			switch SaveStep.next(
				after: confirmation.latest, stored: try await storedPlan(claimed.claim.savedPlan))
			{
			case .done:
				return
			case .writeSavedPlan:
				guard !wrote else { throw .unavailable }
				_ = try await ledger.commit(synced: [.savedPlan(claimed.savedPlan)], stamp: stamp)
				wrote = true
			case .appendSaved:
				do throws(TransitionFailure) {
					_ = try await append(
						.saved(claimed.claim.savedPlan), of: confirmation, in: chat, stamp: stamp,
						after: chain.head)
				} catch {
					switch error {
					case .headMoved: moves += 1
					case .storage(let failure): throw failure
					}
				}
			}
		}
		throw .unavailable
	}

	private func storedPlan(_ id: SavedPlanID) async throws(LedgerFailure) -> SavedPlanBody? {
		try await ledger.read(RecordQuery(scope: .synced([SavedPlans.kind]))).records.lazy
			.compactMap { record -> SavedPlanBody? in
				guard case .synced(.savedPlan(let body)) = record.body, body.id == id else {
					return nil
				}
				return body
			}.first
	}

	private func append(
		_ step: PlanConfirmationStep, of confirmation: FoldedConfirmation, in chat: ChatID,
		stamp: OperationStamp, after head: RecordHead
	) async throws(TransitionFailure) -> AthleteRecord {
		try await append(
			PlanConfirmationBody(
				chat: chat, confirmation: confirmation.id, origin: confirmation.origin, step: step),
			stamp: stamp, after: head)
	}

	private func append(_ body: PlanConfirmationBody, stamp: OperationStamp, after head: RecordHead)
		async throws(TransitionFailure) -> AthleteRecord
	{
		if case .unreadable = head { throw .storage(.unavailable) }
		return try await ledger.append(
			.deviceLocal(.planConfirmation(body)), stamp: stamp, after: head,
			in: .planChain(of: body.chat))
	}

	private var zone: IANATimeZone { AthleteCalendar(clock: clock).deviceZone }

	private func commit(
		_ document: PlanDocument, for key: DraftKey, in chat: ChatID, binding: ActionBinding
	) async -> PlanSettlement {
		let query = RecordQuery.planChain(of: chat)
		let id = PlanConfirmationID(ulid: await ledger.nextULID())
		let expiresAt = clock.now.addingTimeInterval(Self.lifetime / .seconds(1))
		let body = PlanConfirmationBody(
			chat: chat, confirmation: id, origin: key,
			step: .prepared(
				PreparedPlanSave(document: document, account: binding.account, expiresAt: expiresAt)
			))
		let stamp = OperationStamp(
			operation: .turn(key.turn), attempt: key.attempt, binding: binding)
		for _ in 0..<Self.settleAppendAttempts {
			do throws(TransitionFailure) {
				let head: RecordHead
				do throws(LedgerFailure) {
					head = try await ledger.head(of: query)
				} catch {
					throw .storage(error)
				}
				_ = try await append(body, stamp: stamp, after: head)
				wake(chat, at: expiresAt)
				changed.yield(chat)
				return .leftWaiting(id)
			} catch {
				switch error {
				case .headMoved:
					continue
				case .storage(let failure):
					diagnostics.record(.planConfirmationUnavailable(chat, failure))
					return .notPrepared(.notSaved)
				}
			}
		}
		return .notPrepared(.notSaved)
	}

	private func settleDeadAttempt(_ key: DraftKey, in chat: ChatID) async -> PlanSettlement {
		do throws(LedgerFailure) {
			guard let committed = try await chain(of: chat).committed(by: key) else {
				return .nothingWaiting
			}
			return .leftWaiting(committed.id)
		} catch {
			diagnostics.record(.planConfirmationUnavailable(chat, error))
			return .nothingWaiting
		}
	}

	private func chain(of chat: ChatID) async throws(LedgerFailure) -> PlanChain {
		let query = RecordQuery.planChain(of: chat)
		let head = try await ledger.head(of: query)
		return PlanChain(
			head: head,
			records: try await ledger.read(query).records.compactMap(PlanStepRecord.init))
	}

	private func wake(_ chat: ChatID, at expiresAt: Date) {
		if wakes[chat]?.at == expiresAt { return }
		wakes[chat]?.task.cancel()
		let delay = max(0, expiresAt.timeIntervalSince(clock.now))
		let clock = clock
		let changed = changed
		wakes[chat] = PlanWake(
			at: expiresAt,
			task: Task {
				do {
					try await clock.sleep(for: .seconds(delay))
				} catch is CancellationError {
					return
				} catch {
					fatalError("Clock.sleep failed: \(error)")
				}
				changed.yield(chat)
			})
	}
}

private enum PlanPreparation: Sendable, Equatable {
	case held(PlanDocument, ActionBinding)
	case refused
}

private struct PlanWake {
	let at: Date
	let task: Task<Void, Never>
}

extension CoachTools {
	static let planSave = CoachTool.local(
		.preparation(.planSave),
		"Save the athlete's approved training plan. Replaces the stored plan whole — "
			+ "send the full object, unchanged fields included. The host may hold the write "
			+ "for athlete confirmation (pendingConfirmation).",
		parameters: PlanToolSchemas.planSave,
		rerunWith: nil
	) { arguments, reach in
		try await reach.plans.prepare(
			arguments, for: reach.attempt, binding: reach.scope.stamp.binding)
	}
}
