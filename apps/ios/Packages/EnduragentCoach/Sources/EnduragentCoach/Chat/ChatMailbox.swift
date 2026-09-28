import Foundation

package actor ChatMailbox {
	package let chatId: ChatID
	let ledger: Ledger
	private let runner: TurnRunner
	private let flushes: FlushWork
	let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let environment: EnvironmentResolver
	let process: ProcessID

	let records: ChatRecords
	private lazy var resets = PendingResets(
		ConversationReset(chat: chatId, ledger: ledger, flushes: flushes, clock: clock))
	private lazy var start = AttemptStart(
		chat: chatId, records: records, environment: environment,
		freshness: AutomaticReset(chat: chatId, ledger: ledger, flushes: flushes, clock: clock),
		process: process)
	let work = MailboxQueue()
	private let door = Turnstile()
	private(set) var live: LiveAttempt?
	private var running: Task<Void, Never>?
	let interruption = Interruption()
	private let lifetime: Coach.Lifetime
	private var foreground = true
	private(set) var finishedAway: Set<TurnID> = []
	private var leases: LeaseSlot
	private(set) lazy var waits = RetryWaits(clock: clock) { [weak self] in
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
		reviews: any WorkoutReviews,
		process: ProcessID,
		host: any ExecutionHost, lifetime: Coach.Lifetime
	) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.flushes = flushes
		self.clock = clock
		self.coalescing = coalescing
		self.environment = environment
		self.process = process
		self.lifetime = lifetime
		self.leases = LeaseSlot(host: host, chat: chatId) { await environment.appLanguage() }
		self.records = ChatRecords(chat: chatId, ledger: ledger, clock: clock, reviews: reviews)
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
		return try await pass { admitted throws(AcceptFailure) in
			try await admit(Draft(id: draft.id, text: text), slash: slash, admitted)
		}
	}

	package func reset() async -> ResetOutcome {
		do {
			let reset = try await pass { admitted throws(LedgerFailure) in
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

	private func pass<Value, Failure: Error>(
		_ body: nonisolated(nonsending) (borrowing Admitted) async throws(Failure) -> Value
	) async throws(Failure) -> Value {
		try await door.pass { () async throws(Failure) -> Value in
			let admitted = Admitted(work)
			return try await body(admitted)
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
		try await pass { admitted throws(RetryRefusal) in
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
		guard running != nil || work.window != nil || !work.isEmpty || door.held else {
			return
		}
		interruption.begin(cause)
		publish()
		running?.cancel()
		await pass { admitted in
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

	package func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive:
			foreground = true
		case .willResignActive:
			return
		case .enteredBackground:
			foreground = false
			await pass { admitted in closeWindow(admitted) }
		case .willTerminate:
			let owned = interruption.cause == nil
			if owned { interruption.begin(.appTerminating) }
			publish()
			running?.cancel()
			await running?.value
			leases.end { $0.interrupt() }
			if owned { interruption.end() }
			publish()
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
			if work.add(job) { workAdded() }
		}
		publish()
	}

	package func reviewChanged() async {
		await records.refreshReview()
		publish()
	}

	private func stamp(for turn: TurnID) async -> OperationStamp {
		.turn(turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
	}

	private func closeWindowAdmitted(_ armed: Int) async {
		await pass { admitted in closeWindow(admitted, ifArmed: armed) }
	}

	private func closeWindow(_ admitted: borrowing Admitted, ifArmed armed: Int? = nil) {
		guard let turn = admitted.closeWindow(ifArmed: armed) else { return }
		enqueue(turn, admitted)
	}

	private func enqueue(_ turn: TurnID, _ admitted: borrowing Admitted) {
		if admitted.add(turn) { workAdded() }
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
				let access = await self.environment.flushAccess()
				await self.flushes.drain(job, in: self.records.conversation, access: access)
				_ = await self.records.refreshJobs(from: self.flushes)
			case .reset(let reset):
				let access = await self.environment.flushAccess()
				await self.resets.run(reset, on: self.records, access: access) {
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
			if work.window == nil, interruption.cause == nil, !lifetime.terminating {
				leases.end { $0.finish() }
			}
			publish()
		} else {
			drainIfIdle()
		}
	}

	private func holdLease(_ initiator: LeaseInitiator) -> DrainLease? {
		guard !lifetime.terminating else { return nil }
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
		guard
			let request = await start.begin(
				facts, resolution: resolution, stamp: stamp, lease: await lease.kind)
		else { return finish(turn, under: lease) }
		let attempt = stamp.attempt
		live = LiveAttempt(turn: turn, attempt: attempt, text: "", activity: .generating(step: 1))
		publish()
		let scope = TurnScope(stamp: stamp, policy: .npm, uptime: clock.uptime)
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
		if !lifetime.terminating {
			for job in await records.refreshJobs(from: flushes) {
				if work.add(job) { workAdded() }
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
		if case .proposalPending = progress {
			await records.refreshReview()
		}
		guard var current = live, current.attempt == stamp.attempt else {
			publish()
			return
		}
		current.apply(progress)
		live = current
		publish()
	}

	private func publish() {
		feed.publish(snapshot())
	}

	private func waitEnded(_ turn: TurnID, _ attempt: AttemptID) {
		if waits.end(turn, attempt: attempt) { publish() }
	}

	struct Admitted: ~Copyable {
		private let bound: MailboxQueue
		var queue: MailboxQueue { bound }

		fileprivate init(_ queue: MailboxQueue) { bound = queue }
	}
}
