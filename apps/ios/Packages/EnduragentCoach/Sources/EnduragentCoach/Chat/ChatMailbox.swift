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
	private let work = MailboxQueue()
	private var live: LiveAttempt?
	private var running: Task<Void, Never>?
	private let interruption = Interruption()
	private var terminating = false
	private var foreground = true
	private var finishedAway: Set<TurnID> = []
	private var leases: LeaseSlot
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
		return try await work.pass { admitted throws(AcceptFailure) in
			try await admit(Draft(id: draft.id, text: text), slash: slash, admitted)
		}
	}

	package func reset() async -> ResetOutcome {
		do {
			let reset = try await work.pass { admitted throws(LedgerFailure) in
				try await records.load()
				closeWindow(admitted)
				let reset = ResetID(ulid: await ledger.nextULID())
				_ = holdLease(.athlete)
				if admitted.add(reset) { workAdded() }
				return reset
			}
			return await resets.outcome(of: reset)
		} catch {
			return .notStarted(.local(.recordStorage))
		}
	}

	private func admit(
		_ draft: Draft, slash: SlashCommand?, _ admitted: borrowing Admitted
	) async throws(AcceptFailure) -> SendOutcome {
		do {
			try await records.load()
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		if let known = records.conversation.turn(withDraft: draft.id) {
			return .accepted(known.turn)
		}
		let joining: TurnID?
		if let window = work.window, slash == nil {
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
		holdLease(.athlete)?.add(message.turn)
		admitted.arm(message.turn, at: clock.now, for: coalescing.window) { armed in
			await self.closeWindowAdmitted(armed)
		}
		publish()
		return .accepted(message.turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		try await work.pass { admitted throws(RetryRefusal) in
			do {
				try await records.load()
			} catch {
				throw RetryRefusal.unknownTurn
			}
			let waiting = waits.waiting(among: records.conversation.current.turns)
			let queued = work.turns(includingActive: true)
			let overlay = TurnOverlay(
				of: turn, window: work.window, queued: queued, waiting: waiting)
			let refusal = TurnLifecycle.retryRefusal(
				of: records.conversation.turn(turn), overlay: overlay, device: ledger.deviceId,
				process: process)
			if let refusal { throw RetryRefusal(refusal) }
			holdLease(.athlete)?.add(turn)
			enqueue(turn, admitted)
		}
	}

	package func interrupt(_ cause: InterruptionCause) async {
		guard interruption.cause == nil else { return await interruption.join() }
		guard running != nil || work.window != nil || !work.isEmpty || work.held else {
			return
		}
		interruption.begin(cause)
		publish()
		running?.cancel()
		await work.pass { admitted in
			await running?.value
			let unstarted = work.dropWaiting() + [admitted.closeWindow()].compactMap { $0 }
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
			await work.pass { admitted in closeWindow(admitted) }
		case .willTerminate:
			terminating = true
			await terminate()
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
			enqueue(job)
		}
		publish()
	}

	package func refreshProposal() async {
		await records.refreshProposal()
		publish()
	}

	private func stamp(for turn: TurnID) async -> OperationStamp {
		.turn(turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
	}

	private func closeWindowAdmitted(_ armed: Int) async {
		await work.pass { admitted in closeWindow(admitted, ifArmed: armed) }
	}

	private func closeWindow(_ admitted: borrowing Admitted, ifArmed armed: Int? = nil) {
		guard let turn = admitted.closeWindow(ifArmed: armed) else { return }
		enqueue(turn, admitted)
	}

	private func enqueue(_ turn: TurnID, _ admitted: borrowing Admitted) {
		if admitted.add(turn) { workAdded() }
	}

	private func enqueue(_ job: FlushJobID) {
		if work.add(job) { workAdded() }
	}

	private func workAdded() {
		publish()
		drainIfIdle()
	}

	private func drainIfIdle() {
		guard running == nil, interruption.cause == nil, let initiator = work.next?.initiator,
			let lease = holdLease(initiator), let next = work.start()
		else { return }
		running = Task {
			switch next {
			case .turn(let turn):
				await self.runTurn(turn, under: lease)
			case .flush(let job):
				await self.flushes.drain(
					job, in: self.records.conversation, access: self.environment.access)
				_ = await self.records.refreshJobs(from: self.flushes)
			case .reset(let reset):
				await self.resets.run(reset, on: self.records, access: self.environment.access) {
					self.publish()
				}
			}
			self.workFinished()
		}
	}

	private func workFinished() {
		running = nil
		work.finish()
		if work.isEmpty {
			if work.window == nil, interruption.cause == nil, !terminating {
				leases.end { $0.finish() }
			}
			publish()
		} else {
			drainIfIdle()
		}
	}

	private func holdLease(_ initiator: LeaseInitiator) -> DrainLease? {
		guard !terminating else { return nil }
		return leases.hold(initiator) { [weak self] generation, cause in
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
			for job in await records.refreshJobs(from: flushes) {
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
			window: work.window,
			queued: work.turns(includingActive: true),
			waiting: waits.waiting(among: records.conversation.current.turns),
			stopping: interruption.cause != nil,
			resetting: work.resetting,
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
