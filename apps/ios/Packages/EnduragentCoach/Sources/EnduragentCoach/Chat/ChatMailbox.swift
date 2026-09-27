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

	private var loaded = false
	private var loading: Task<Result<Void, LedgerFailure>, Never>?
	private let records: TurnRecords
	private var pendingProposal: PendingProposal?
	private var work = MailboxQueue()
	private var window = JoinWindow()
	private var live: LiveAttempt?
	private var running: Task<Void, Never>?
	private let interruption = Interruption()
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
		self.records = TurnRecords(chat: chatId, ledger: ledger, clock: clock)
	}

	package func observe() async -> AsyncStream<ChatSnapshot> {
		do {
			try await load()
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
		if slash == .language {
			return .showLanguagePicker
		}
		return try await admission.pass { admitted throws(AcceptFailure) in
			try await admit(Draft(id: draft.id, text: text), slash: slash, admitted)
		}
	}

	private func admit(
		_ draft: Draft, slash: SlashCommand?, _ admitted: borrowing Admitted
	) async throws(AcceptFailure) -> SendOutcome {
		do {
			try await load()
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
			closeWindow(admitted)
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
		window.arm(message.turn, at: clock.now, for: coalescing.window, admitted) { armed in
			await self.closeWindowAdmitted(armed)
		}
		publish()
		return .accepted(message.turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		try await admission.pass { admitted throws(RetryRefusal) in
			do {
				try await load()
			} catch {
				throw RetryRefusal.unknownTurn
			}
			let waiting = waits.waiting(among: records.conversation.current.turns)
			let queued = work.turns(includingActive: true)
			let overlay = TurnOverlay(
				of: turn, window: window.open, queued: queued, waiting: waiting)
			let refusal = TurnLifecycle.retryRefusal(
				of: records.conversation.turn(turn), overlay: overlay, device: ledger.deviceId,
				process: process)
			if let refusal { throw RetryRefusal(refusal) }
			holdLease(.athlete).add(turn)
			enqueue(turn, admitted)
		}
	}

	package func interrupt(_ cause: InterruptionCause) async {
		guard interruption.cause == nil else { return await interruption.join() }
		guard running != nil || window.open != nil || !work.isEmpty || admission.held else {
			return
		}
		interruption.begin(cause)
		publish()
		running?.cancel()
		await admission.pass { _ in
			await running?.value
			let unstarted = work.dropWaiting() + [window.close()].compactMap { $0 }
			for turn in unstarted {
				let stamp = await stamp(for: turn)
				await records.settle(turn, .stopBeforeStart(stamp.attempt), stamp: stamp)
			}
			interruption.end()
			leases.end { $0.interrupt() }
		}
		publish()
		drainIfIdle()
	}

	private func terminate() async {
		let owned = interruption.cause == nil
		if owned { interruption.begin(.appTerminating) }
		publish()
		running?.cancel()
		await running?.value
		leases.end { $0.interrupt() }
		if owned { interruption.end() }
		publish()
	}

	package func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive:
			foreground = true
		case .willResignActive:
			return
		case .enteredBackground:
			foreground = false
			await admission.pass { admitted in closeWindow(admitted) }
		case .willTerminate:
			terminating = true
			await terminate()
		}
	}

	package func recover(_ plan: RecoveryPlan) async throws(LedgerFailure) {
		try await load()
		for dead in plan.interrupt {
			let stamp = OperationStamp.turn(dead.turn, attempt: dead.attempt, clock: clock)
			await records.settle(
				dead.turn, .recoverDeadClaim(dead.attempt, saved: dead.saved), stamp: stamp)
		}
		for job in plan.drain {
			enqueue(job)
		}
		publish()
	}

	package func refreshProposal() async {
		do {
			pendingProposal = try await ProposalPolicy.pending(chatId, from: ledger, at: clock.now)
		} catch {
			pendingProposal = nil
		}
		publish()
	}

	private func load() async throws(LedgerFailure) {
		guard !loaded else { return }
		let reading = loading ?? Task { await self.read() }
		loading = reading
		try await reading.value.get()
	}

	private func read() async -> Result<Void, LedgerFailure> {
		defer { loading = nil }
		do {
			let folded = try await ledger.conversation(chatId)
			pendingProposal = try await ProposalPolicy.pending(chatId, from: ledger, at: clock.now)
			records.replace(with: folded)
			loaded = true
			return .success(())
		} catch {
			return .failure(error)
		}
	}

	private func stamp(for turn: TurnID) async -> OperationStamp {
		.turn(turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
	}

	private func closeWindowAdmitted(_ armed: Int) async {
		await admission.pass { admitted in closeWindow(admitted, ifArmed: armed) }
	}

	private func closeWindow(_ admitted: borrowing Admitted, ifArmed armed: Int? = nil) {
		guard let turn = window.close(ifArmed: armed) else { return }
		enqueue(turn, admitted)
	}

	private func enqueue(_ turn: TurnID, _ admitted: borrowing Admitted) {
		if work.add(turn, admitted) { workAdded() }
	}

	private func enqueue(_ job: FlushJobID) {
		if work.add(job) { workAdded() }
	}

	private func workAdded() {
		publish()
		drainIfIdle()
	}

	private func drainIfIdle() {
		guard running == nil, interruption.cause == nil, !terminating, let next = work.start()
		else { return }
		let lease = holdLease(next.turn == nil ? .recovery : .athlete)
		running = Task {
			switch next {
			case .turn(let turn):
				await self.runTurn(turn, under: lease)
			case .flush(let job):
				await self.flushes.drain(
					job, in: self.records.conversation, access: self.environment.access)
			}
			self.workFinished()
		}
	}

	private func workFinished() {
		running = nil
		work.finish()
		if work.isEmpty {
			if window.open == nil, interruption.cause == nil, !terminating {
				leases.end { $0.finish() }
			}
			publish()
		} else {
			drainIfIdle()
		}
	}

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
		let resolution = await environment.resolve()
		let stamp = await stamp(for: turn).bound(to: resolution.account)
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
		let resolved: AttemptEnvironment
		do {
			resolved = try resolution.get()
		} catch {
			let unavailable = Settlement.failed(.model(.accessUnavailable(error)), saved: .none)
			await records.settle(turn, .settle(attempt, unavailable), stamp: stamp)
			return finish(turn, under: lease)
		}
		live = LiveAttempt(turn: turn, attempt: attempt, text: "", activity: .generating(step: 1))
		publish()
		let scope = TurnScope(stamp: stamp, policy: .npm, uptime: clock.uptime)
		let request = await environment.attempt(
			of: facts, attempt: attempt, chat: chatId, process: process, in: resolved)
		let settlement: Settlement
		do {
			let result = try await runner.run(request, scope: scope) { progress in
				lease.observe(progress)
				await self.apply(progress, turn: turn, stamp: stamp)
			}
			settlement = Settlement(result)
		} catch {
			settlement = .interrupted(
				partial: live?.text ?? "", cause: interruption.cause ?? .athleteStopped,
				saved: await scope.summary)
		}
		await records.settle(turn, .settle(attempt, settlement), stamp: stamp)
		finish(turn, under: lease)
		if !terminating {
			for job in await flushes.pending() {
				enqueue(job)
			}
		}
	}

	private func finish(_ turn: TurnID, under lease: DrainLease) {
		live = nil
		work.finish()
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
			pendingProposal = proposal
		}
		current.apply(progress)
		live = current
		publish()
	}

	private func snapshot() -> ChatSnapshot {
		ChatSnapshot(
			chat: chatId,
			conversation: records.conversation,
			live: live,
			window: window.open,
			queued: work.turns(includingActive: true),
			waiting: waits.waiting(among: records.conversation.current.turns),
			stopping: interruption.cause != nil,
			finishedAway: finishedAway,
			pendingProposal: pendingProposal,
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
