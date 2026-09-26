import Foundation

package actor ChatMailbox {
	package let chatId: ChatID
	private let ledger: Ledger
	private let runner: TurnRunner
	private let flushes: FlushWork
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let environment: EnvironmentResolver
	private let diagnostics: DiagnosticsLog
	private let host: any ExecutionHost

	private var loaded = false
	private var conversation: Conversation
	private var pendingProposal: PendingProposal?
	private var work: [MailboxWork] = []
	private var active: MailboxWork?
	private var window = JoinWindow()
	private var live: LiveAttempt?
	private var running: Task<Void, Never>?
	private var stopping: InterruptionCause?
	private var terminating = false
	private var foreground = true
	private var finishedAway: Set<TurnID> = []
	private var lease: DrainLease?
	private var leaseGeneration = 0
	private let feed = SnapshotFeed()

	package init(
		chatId: ChatID,
		ledger: Ledger,
		runner: TurnRunner,
		memory: Memory,
		transport: any ModelTransport,
		clock: any Clock,
		coalescing: CoalescingPolicy,
		environment: EnvironmentResolver,
		diagnostics: DiagnosticsLog,
		host: any ExecutionHost
	) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.flushes = FlushWork(
			chat: chatId, ledger: ledger, memory: memory, transport: transport, clock: clock,
			diagnostics: diagnostics)
		self.clock = clock
		self.coalescing = coalescing
		self.environment = environment
		self.diagnostics = diagnostics
		self.host = host
		self.conversation = Conversation(chat: chatId, segments: [])
	}

	package func observe() async -> AsyncStream<ChatSnapshot> {
		await loadIfNeeded()
		return feed.subscribe(from: snapshot())
	}

	package func accept(_ draft: Draft) async throws(AcceptFailure) -> SendOutcome {
		let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return .ignoredBlank }
		let slash = SlashRouting.parse(text)
		if slash == .language {
			return .showLanguagePicker
		}
		do {
			try await load()
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		if let known = conversation.turn(withDraft: draft.id) {
			return .accepted(known.turn)
		}
		let joining: TurnID?
		if let open = window.open, slash == nil {
			joining = open.turn
		} else {
			closeWindow()
			joining = nil
		}
		let minted = TurnID(ulid: await ledger.nextULID())
		let writes = TurnLifecycle.writes(
			for: .accept(Draft(id: draft.id, text: text), joining: joining, slash: slash),
			on: joining.flatMap(conversation.turn),
			chat: chatId,
			device: ledger.deviceId,
			mint: { minted }
		)
		guard case .success(.synced(let bodies)) = writes,
			case .userMessage(let message)? = bodies.first
		else {
			guard let joining else { throw AcceptFailure.storageUnavailable }
			return .accepted(joining)
		}
		do {
			try await commit(.synced(bodies), stamp: await stamp(for: message.turn))
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		holdLease(.athlete).add(message.turn)
		window.arm(message.turn, at: clock.now, for: coalescing.window) { armed in
			await self.closeWindow(ifArmed: armed)
		}
		publish()
		return .accepted(message.turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		await loadIfNeeded()
		guard let facts = conversation.turn(turn) else { throw RetryRefusal.unknownTurn }
		if live?.turn == turn || window.open?.turn == turn || work.contains(.turn(turn)) {
			throw RetryRefusal.alreadyRunning
		}
		if let refusal = TurnLifecycle.claimRefusal(of: facts, device: ledger.deviceId) {
			throw RetryRefusal(refusal)
		}
		holdLease(.athlete).add(turn)
		enqueue(.turn(turn))
	}

	package func interrupt(_ cause: InterruptionCause) async {
		guard stopping == nil else {
			await running?.value
			return
		}
		guard running != nil || window.open != nil || !work.isEmpty else { return }
		stopping = cause
		publish()
		let closed = [window.close()].compactMap { $0 }
		let unstarted = terminating ? [] : queuedTurns(includingActive: false) + closed
		work.removeAll()
		running?.cancel()
		await running?.value
		for turn in unstarted {
			let stamp = await stamp(for: turn)
			await settle(turn, .stopBeforeStart(stamp.attempt), stamp: stamp)
		}
		work.removeAll { $0.turn == nil }
		stopping = nil
		lease?.interrupt()
		lease = nil
		publish()
		drainIfIdle()
	}

	package func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive:
			foreground = true
		case .willResignActive:
			return
		case .enteredBackground:
			foreground = false
			closeWindow()
		case .willTerminate:
			terminating = true
			await interrupt(.appTerminating)
		}
	}

	package func recover(_ plan: RecoveryPlan) async {
		await loadIfNeeded()
		for dead in plan.interrupt {
			let stamp = await stamp(for: dead.turn, attempt: dead.attempt)
			await settle(
				dead.turn, .recoverDeadClaim(dead.attempt, saved: dead.saved), stamp: stamp)
		}
		for job in plan.drain {
			enqueueFlush(job)
		}
		publish()
	}

	private func queuedTurns(includingActive: Bool) -> [TurnID] {
		let items = includingActive ? [active].compactMap { $0 } + work : work
		return items.compactMap(\.turn)
	}

	package func refreshProposal() async {
		do {
			pendingProposal = try await ledger.pendingProposal(chatId, now: clock.now)
		} catch {
			pendingProposal = nil
		}
		publish()
	}

	private func loadIfNeeded() async {
		do {
			try await load()
		} catch {
			conversation = Conversation(chat: chatId, segments: [])
		}
	}

	private func load() async throws(LedgerFailure) {
		guard !loaded else { return }
		conversation = try await ledger.conversation(chatId)
		pendingProposal = try await ledger.pendingProposal(chatId, now: clock.now)
		loaded = true
	}

	private func stamp(for turn: TurnID, attempt known: AttemptID? = nil) async -> OperationStamp {
		let attempt = if let known { known } else { AttemptID(ulid: await ledger.nextULID()) }
		return .turn(turn, attempt: attempt, clock: clock)
	}

	private func commit(_ writes: TurnWrites, stamp: OperationStamp) async throws(LedgerFailure) {
		let records = try await ledger.commit(writes, stamp: stamp)
		conversation = ConversationFold.applying(records, to: conversation, device: ledger.deviceId)
	}

	private func closeWindow(ifArmed armed: Int? = nil) {
		guard let turn = window.close(ifArmed: armed) else { return }
		enqueue(.turn(turn))
	}

	private func enqueue(_ item: MailboxWork) {
		work.append(item)
		publish()
		drainIfIdle()
	}

	private func enqueueFlush(_ job: FlushJobID) {
		guard active != .flush(job), !work.contains(.flush(job)) else { return }
		enqueue(.flush(job))
	}

	private func drainIfIdle() {
		guard running == nil, stopping == nil, !terminating, !work.isEmpty else { return }
		let next = work.removeFirst()
		let lease = holdLease(next.turn == nil ? .recovery : .athlete)
		active = next
		running = Task {
			switch next {
			case .turn(let turn):
				await self.runTurn(turn, under: lease)
			case .flush(let job):
				await self.flushes.drain(
					job, in: self.conversation, access: self.environment.access)
			}
			self.workFinished()
		}
	}

	private func workFinished() {
		running = nil
		active = nil
		drainIfIdle()
		if running == nil, window.open == nil, stopping == nil, !terminating, let lease {
			self.lease = nil
			lease.finish()
		}
		publish()
	}

	private func holdLease(_ initiator: LeaseInitiator) -> DrainLease {
		if let lease, lease.covers(initiator) {
			return lease
		}
		lease?.finish()
		leaseGeneration += 1
		let generation = leaseGeneration
		let begun = DrainLease(generation, host: host, chat: chatId, initiator: initiator) {
			[weak self] cause in
			await self?.expire(cause, lease: generation)
		}
		lease = begun
		return begun
	}

	private func expire(_ cause: ExpiryCause, lease generation: Int) async {
		guard lease?.generation == generation else { return }
		await interrupt(InterruptionCause(cause))
	}

	private func runTurn(_ turn: TurnID, under lease: DrainLease) async {
		guard let facts = conversation.turn(turn) else { return }
		lease.add(turn)
		let stamp = await stamp(for: turn)
		let attempt = stamp.attempt
		let kind = await lease.kind
		let claiming = conversation.writes(
			.claim(attempt, lease: kind), for: turn, device: ledger.deviceId)
		guard case .success(let claim) = claiming else { return }
		do {
			try await commit(claim, stamp: stamp)
		} catch {
			await settleUnsaved(
				turn, attempt: attempt, .failed(.local(.recordStorage), saved: .none))
			finish(turn, under: lease)
			return
		}
		let access: ResolvedAccess
		do {
			access = try environment.access()
		} catch {
			await settle(
				turn, .settle(attempt, .failed(.model(.accessUnavailable(error)), saved: .none)),
				stamp: stamp)
			finish(turn, under: lease)
			return
		}
		live = LiveAttempt(turn: turn, attempt: attempt, text: "", activity: .generating(step: 1))
		publish()
		let scope = TurnScope(stamp: stamp, policy: .npm, uptime: clock.uptime)
		let request = TurnAttempt(
			turn: turn, attempt: attempt, chat: chatId, request: facts.requestText,
			slash: facts.slash, language: await environment.language(), access: access)
		let settlement: Settlement
		do {
			let result = try await runner.run(request, scope: scope) { progress in
				lease.observe(progress)
				await self.apply(progress, stamp: stamp)
			}
			settlement = Settlement(result)
		} catch {
			settlement = .interrupted(
				partial: live?.text ?? "", cause: stopping ?? .athleteStopped,
				saved: WriteSummary(await scope.written))
		}
		await settle(turn, .settle(attempt, settlement), stamp: stamp)
		finish(turn, under: lease)
		if !terminating {
			for job in await flushes.pending() {
				enqueueFlush(job)
			}
		}
	}

	private func finish(_ turn: TurnID, under lease: DrainLease) {
		if active == .turn(turn) {
			active = nil
		}
		live = nil
		let reply = conversation.turn(turn)?.reply
		if reply != nil, !foreground {
			finishedAway.insert(turn)
		}
		lease.settle(turn, reply: reply)
		publish()
	}

	private func settle(_ turn: TurnID, _ event: TurnEvent, stamp: OperationStamp) async {
		guard
			case .success(let planned) = conversation.writes(
				event, for: turn, device: ledger.deviceId),
			case .synced(let bodies) = planned, case .turnSettled(let settled)? = bodies.first
		else {
			return
		}
		do {
			try await commit(planned, stamp: stamp)
		} catch {
			await settleUnsaved(turn, attempt: settled.attempt, settled.settlement)
		}
	}

	private func settleUnsaved(_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement) async {
		let ulid = await ledger.nextULID()
		conversation.settleUnsaved(
			turn, attempt: attempt, settlement, ulid: ulid, device: ledger.deviceId, clock: clock)
	}

	private func apply(_ progress: AttemptProgress, stamp: OperationStamp) async {
		guard let observing = live, observing.attempt == stamp.attempt else { return }
		if case .textDelta(let delta) = progress, !delta.isEmpty,
			case .success(let mark) = conversation.writes(
				.observeReply(stamp.attempt), for: observing.turn, device: ledger.deviceId)
		{
			do {
				try await commit(mark, stamp: stamp)
			} catch {
				diagnostics.record(.replyObservedUnsaved(stamp.attempt, detail: "\(error)"))
			}
		}
		guard var current = live, current.attempt == stamp.attempt else { return }
		if case .proposalPending(let proposal) = progress {
			pendingProposal = proposal
		}
		current.apply(progress)
		live = current
		publish()
	}

	private func snapshot() -> ChatSnapshot {
		ChatSnapshot(
			chat: chatId, conversation: conversation, live: live, window: window.open,
			queued: queuedTurns(includingActive: true), stopping: stopping != nil,
			finishedAway: finishedAway, pendingProposal: pendingProposal, device: ledger.deviceId,
			clock: clock)
	}

	private func publish() {
		feed.publish(snapshot())
	}
}
