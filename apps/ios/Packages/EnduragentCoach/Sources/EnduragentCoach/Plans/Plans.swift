import Foundation

package actor Plans {
	static let lifetime: Duration = .seconds(600)
	static let settleAppendAttempts = 3

	private let ledger: Ledger
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private var preparations: [DraftKey: PlanPreparation] = [:]
	private var deliveries: [ChatID: PlanDelivery] = [:]
	private var wakes: [ChatID: PlanWake] = [:]
	nonisolated let changes: AsyncStream<ChatID>
	private let changed: AsyncStream<ChatID>.Continuation

	package init(ledger: Ledger, clock: any Clock, diagnostics: DiagnosticsLog) {
		self.ledger = ledger
		self.clock = clock
		self.diagnostics = diagnostics
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
			conversation: try await ledger.conversation(chat), delivery: delivery, at: clock.now)
	}

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
				let head = try await headForAppend(of: query, in: chat)
				_ = try await ledger.append(
					.deviceLocal(.planConfirmation(body)), stamp: stamp, after: head, in: query)
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

	private func headForAppend(of query: RecordQuery, in chat: ChatID)
		async throws(TransitionFailure) -> RecordHead
	{
		let head: RecordHead
		do throws(LedgerFailure) {
			head = try await ledger.head(of: query)
		} catch {
			throw .storage(error)
		}
		guard case .unreadable = head else { return head }
		throw .storage(.unavailable)
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

enum PlanSettlement: Sendable, Equatable {
	case nothingWaiting
	case leftWaiting(PlanConfirmationID)
	case notPrepared(PlanSaveNotPrepared)

	func counted(in settlement: Settlement) -> Settlement {
		guard case .leftWaiting = self,
			case .interrupted(let partial, .processEnded, let saved) = settlement
		else { return settlement }
		return .interrupted(
			partial: partial, cause: .processEnded,
			saved: WriteSummary(
				memorySections: saved.memorySections, ledgerEvents: saved.ledgerEvents,
				planConfirmations: 1, calendarWrites: saved.calendarWrites,
				unverifiedCalendarWrites: saved.unverifiedCalendarWrites))
	}

	var notPrepared: PlanSaveNotPrepared? {
		guard case .notPrepared(let cause) = self else { return nil }
		return cause
	}
}

package enum PlanSaveNotPrepared: String, Equatable, Sendable {
	case refused
	case notSaved
	case turnDidNotFinish
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
