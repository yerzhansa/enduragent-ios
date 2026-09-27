import Foundation

package actor ChatMailbox {
	package let chatId: ChatID
	private let ledger: Ledger
	private let runner: TurnRunner
	private let flushes: FlushWork
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let environment: EnvironmentResolver
	private let process: ProcessID

	private let records: ChatRecords
	private lazy var resets = PendingResets(
		ConversationReset(chat: chatId, ledger: ledger, flushes: flushes, clock: clock))
	private var work: [MailboxWork] = []
	private var active: MailboxWork?
	private var window = JoinWindow()
	private var live: LiveAttempt?
	private var running: Task<Void, Never>?
	private var interruption: InterruptionCause?
	private var terminating = false
	private var foreground = true
	private var finishedAway: Set<TurnID> = []
	private var leases: LeaseSlot
	private let admission = Admission()
	private lazy var waits = RetryWaits(clock: clock) { [weak self] in
		await self?.waitEnded($0, $1)
	}
	private let feed = SnapshotFeed()

	package init(
		chatId: ChatID,
		ledger: Ledger,
		runner: TurnRunner,
		flushes: FlushWork,
		clock: any Clock,
		coalescing: CoalescingPolicy,
		environment: EnvironmentResolver,
		process: ProcessID,
		host: any ExecutionHost
	) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.flushes = flushes
		self.clock = clock
		self.coalescing = coalescing
		self.environment = environment
		self.process = process
		self.leases = LeaseSlot(host: host, chat: chatId)
		self.records = ChatRecords(chat: chatId, ledger: ledger, clock: clock)
	}

	package func observe() async -> AsyncStream<ChatSnapshot> {
		do {
			try await records.load()
		} catch {
			switch error {
			case .unavailable, .rejectedBatch:
				break
			}
		}
		return feed.subscribe(from: snapshot())
	}

	package func accept(_ draft: Draft) async throws(AcceptFailure) -> SendOutcome {
		let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return .ignoredBlank }
		let slash = SlashRouting.parse(text)
		switch slash?.route {
		case .languagePicker: return .showLanguagePicker
		case .resetConversation: return .newConversation(await reset())
		case .modelTurn, nil: break
		}
		await admission.enter()
		defer { admission.leave() }
		return try await admit(Draft(id: draft.id, text: text), slash: slash)
	}

	package func reset() async -> ResetOutcome {
		await admission.enter()
		do {
			try await records.load()
		} catch {
			admission.leave()
			return .notStarted(.local(.recordStorage))
		}
		closeWindow()
		let reset = ResetID(ulid: await ledger.nextULID())
		holdLease(.athlete)
		return await resets.outcome(of: reset) {
			enqueue(.reset(reset))
			admission.leave()
		}
	}

	private func admit(_ draft: Draft, slash: SlashCommand?) async throws(AcceptFailure)
		-> SendOutcome
	{
		do {
			try await records.load()
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		if let known = records.conversation.turn(withDraft: draft.id) {
			return .accepted(known.turn)
		}
		let joining: TurnID?
		if let window = window.open, slash == nil {
			joining = window.turn
		} else {
			closeWindow()
			joining = nil
		}
		let minted = TurnID(ulid: await ledger.nextULID())
		let writes = TurnLifecycle.writes(
			for: .accept(draft, joining: joining, slash: slash),
			on: joining.flatMap(records.conversation.turn),
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
			try await records.commit(.synced(bodies), stamp: await stamp(for: message.turn))
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		holdLease(.athlete).add(message.turn)
		window.arm(message.turn, at: clock.now, for: coalescing.window) { armed in
			await self.closeWindowAdmitted(armed)
		}
		publish()
		return .accepted(message.turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		do {
			try await records.load()
		} catch {
			throw RetryRefusal.unknownTurn
		}
		let waiting = waits.waiting(among: records.conversation.current.turns)
		let queued = queuedTurns(includingActive: true)
		let overlay = TurnOverlay(of: turn, window: window.open, queued: queued, waiting: waiting)
		let refusal = TurnLifecycle.retryRefusal(
			of: records.conversation.turn(turn), overlay: overlay, device: ledger.deviceId,
			process: process)
		if let refusal { throw RetryRefusal(refusal) }
		holdLease(.athlete).add(turn)
		enqueue(.turn(turn))
	}

	package func interrupt(_ cause: InterruptionCause) async {
		let active = running
		guard active != nil || window.open != nil || !work.isEmpty else { return }
		interruption = cause
		publish()
		active?.cancel()
		await active?.value
		if !terminating {
			await admission.enter()
			let unstarted = queuedTurns(includingActive: false) + [window.close()].compactMap { $0 }
			work.removeAll { $0.reset == nil }
			for turn in unstarted {
				let stamp = await stamp(for: turn)
				await records.settle(turn, .stopBeforeStart(stamp.attempt), stamp: stamp)
			}
			admission.leave()
		}
		interruption = nil
		leases.end { $0.interrupt() }
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
			await admission.enter()
			closeWindow()
			admission.leave()
		case .willTerminate:
			terminating = true
			await interrupt(.appTerminating)
		}
	}

	package func recover(_ plan: RecoveryPlan) async throws(LedgerFailure) {
		try await records.load()
		for dead in plan.interrupt {
			let stamp = OperationStamp.turn(dead.turn, attempt: dead.attempt, clock: clock)
			await records.settle(
				dead.turn, .recoverDeadClaim(dead.attempt, saved: dead.saved), stamp: stamp)
		}
		for job in plan.drain {
			enqueue(.flush(job))
		}
		publish()
	}

	private func queuedTurns(includingActive: Bool) -> [TurnID] {
		let items = includingActive ? [active].compactMap { $0 } + work : work
		return items.compactMap(\.turn)
	}

	package func refreshProposal() async {
		await records.refreshProposal()
		publish()
	}

	private func stamp(for turn: TurnID) async -> OperationStamp {
		.turn(turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
	}

	private func closeWindowAdmitted(_ armed: Int) async {
		await admission.enter()
		closeWindow(ifArmed: armed)
		admission.leave()
	}

	private func closeWindow(ifArmed armed: Int? = nil) {
		guard let turn = window.close(ifArmed: armed) else { return }
		enqueue(.turn(turn))
	}

	private func enqueue(_ item: MailboxWork) {
		guard active != item, !work.contains(item) else { return }
		work.append(item)
		publish()
		drainIfIdle()
	}

	private func drainIfIdle() {
		guard running == nil, interruption == nil, !terminating, !work.isEmpty else { return }
		let next = work.removeFirst()
		let lease = holdLease(next.initiator)
		active = next
		running = Task {
			switch next {
			case .turn(let turn):
				await self.runTurn(turn, under: lease)
			case .flush(let job):
				await self.flushes.drain(
					job, in: self.records.conversation, access: self.environment.access)
				_ = await self.records.refreshJobs(from: self.flushes)
			case .reset(let reset):
				let outcome = await self.resets.run(
					reset, on: self.records, access: self.environment.access)
				self.publish()
				self.resets.finish(reset, outcome)
			}
			self.workFinished()
		}
	}

	private func workFinished() {
		running = nil
		active = nil
		if work.isEmpty {
			if window.open == nil, interruption == nil, !terminating {
				leases.end { $0.finish() }
			}
			publish()
		} else {
			drainIfIdle()
		}
	}

	@discardableResult
	private func holdLease(_ initiator: LeaseInitiator) -> DrainLease {
		leases.hold(initiator) { [weak self] generation, cause in
			await self?.expire(cause, lease: generation)
		}
	}

	private func expire(_ cause: ExpiryCause, lease generation: Int) async {
		guard leases.holds(generation) else { return }
		await interrupt(InterruptionCause(cause))
	}

	private func runTurn(_ turn: TurnID, under lease: DrainLease) async {
		guard let facts = records.conversation.turn(turn) else { return }
		lease.add(turn)
		let stamp = await stamp(for: turn)
		let attempt = stamp.attempt
		let claiming = records.writes(
			.claim(attempt, process: process, lease: await lease.kind), for: turn)
		guard case .success(let claim) = claiming else { return finish(turn, under: lease) }
		do {
			try await records.commit(claim, stamp: stamp)
		} catch {
			await records.settleUnsaved(
				turn, attempt: attempt, .failed(.local(.recordStorage), saved: .none))
			return finish(turn, under: lease)
		}
		let access: ResolvedAccess
		do {
			access = try environment.access()
		} catch {
			let unavailable = Settlement.failed(.model(.accessUnavailable(error)), saved: .none)
			await records.settle(turn, .settle(attempt, unavailable), stamp: stamp)
			return finish(turn, under: lease)
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
				await self.apply(progress, turn: turn, stamp: stamp)
			}
			settlement = Settlement(result)
		} catch {
			settlement = .interrupted(
				partial: live?.text ?? "", cause: interruption ?? .athleteStopped,
				saved: await scope.summary)
		}
		await records.settle(turn, .settle(attempt, settlement), stamp: stamp)
		finish(turn, under: lease)
		if !terminating {
			for job in await records.refreshJobs(from: flushes) {
				enqueue(.flush(job))
			}
		}
	}

	private func finish(_ turn: TurnID, under lease: DrainLease) {
		live = nil
		active = nil
		let reply = records.conversation.turn(turn)?.reply
		if reply != nil, !foreground {
			finishedAway.insert(turn)
		}
		lease.settle(turn, reply: reply)
		publish()
	}

	private func apply(_ progress: AttemptProgress, turn: TurnID, stamp: OperationStamp) async {
		if case .textDelta(let delta) = progress, !delta.isEmpty {
			await records.observeReply(turn, stamp: stamp)
		}
		guard var current = live, current.attempt == stamp.attempt else { return }
		if case .proposalPending(let proposal) = progress {
			records.pendingProposal = proposal
		}
		current.apply(progress)
		live = current
		publish()
	}

	private func snapshot() -> ChatSnapshot {
		ChatSnapshot(
			chat: chatId,
			conversation: records.conversation,
			jobs: records.jobs,
			live: live,
			window: window.open,
			queued: queuedTurns(includingActive: true),
			waiting: waits.waiting(among: records.conversation.current.turns),
			stopping: interruption != nil,
			finishedAway: finishedAway,
			pendingProposal: records.pendingProposal,
			device: ledger.deviceId,
			process: process,
			now: clock.now,
			zone: clock.timeZone
		)
	}

	private func publish() {
		feed.publish(snapshot())
	}

	private func waitEnded(_ turn: TurnID, _ attempt: AttemptID) {
		if waits.end(turn, attempt: attempt) { publish() }
	}
}
