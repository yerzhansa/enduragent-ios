import Foundation

package actor ChatMailbox {
	package let chatId: ChatID
	private let ledger: Ledger
	private let runner: TurnRunner
	private let flushes: FlushWork
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let coalescingSleep: @Sendable (Duration) async throws -> Void
	private let environment: EnvironmentResolver
	private let process: ProcessID

	private let records: ChatRecords
	private lazy var resets = PendingResets(
		ConversationReset(chat: chatId, ledger: ledger, flushes: flushes, clock: clock))
	private lazy var start = AttemptStart(
		chat: chatId, ledger: ledger, records: records, environment: environment, process: process)
	private let work = MailboxQueue()
	private let door = Turnstile()
	private let lifetime: Coach.Lifetime
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
		coalescingSleep: @escaping @Sendable (Duration) async throws -> Void = SystemClock().sleep,
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
		self.coalescingSleep = coalescingSleep
		self.environment = environment
		self.process = process
		self.lifetime = lifetime
		self.leases = LeaseSlot(host: host, chat: chatId) { await environment.appLanguage() }
		self.records = ChatRecords(chat: chatId, ledger: ledger, clock: clock, reviews: reviews)
	}

	var conversation: Conversation { records.conversation }

	package func hasLocalWork() async throws(LedgerFailure) -> Bool {
		let stored = try await ledger.hasLocalWork(in: chatId, now: clock.now)
		return stored || work.phase.running != nil || work.phase.cause != nil
			|| work.window != nil || !work.isEmpty || door.held
			|| conversation.hasLocalWork(on: ledger.deviceId)
	}

	package func observe() async -> AsyncStream<ChatSnapshot> {
		await records.loadForObservation()
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
		return try await door.pass { () throws(AcceptFailure) in
			try await admit(Draft(id: draft.id, text: text), slash: slash)
		}
	}

	package func reset() async -> ResetOutcome {
		do {
			let reset = try await door.pass { () throws(LedgerFailure) in
				try await records.load()
				closeWindow()
				let reset = ResetID(ulid: await ledger.nextULID())
				_ = holdLease(.athlete)
				if work.add(reset) { workAdded() }
				return reset
			}
			return await resets.outcome(of: reset)
		} catch {
			return .notStarted(.local(.recordStorage))
		}
	}

	private func admit(
		_ draft: Draft, slash: SlashCommand?
	) async throws(AcceptFailure) -> SendOutcome {
		do {
			try await records.load()
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		if let known = conversation.turn(withDraft: draft.id) {
			return .accepted(known.turn)
		}
		let turn: TurnID
		let fragment: Int
		if let window = work.window, slash == nil, let facts = conversation.turn(window.turn) {
			turn = facts.turn
			fragment = facts.fragments.count
		} else {
			closeWindow()
			turn = TurnID(ulid: await ledger.nextULID())
			fragment = 0
		}
		let message = TurnLifecycle.accept(
			draft, turn: turn, fragment: fragment, chat: chatId, slash: slash)
		do {
			let stamp = await stamp(for: turn)
			records.apply(try await ledger.commit(synced: [.userMessage(message)], stamp: stamp))
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		holdLease(.athlete)?.add(turn)
		armWindow(for: turn)
		publish()
		return .accepted(turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		try await door.pass { () throws(RetryRefusal) in
			do {
				try await records.load()
			} catch {
				throw RetryRefusal.unknownTurn
			}
			let waiting = waits.waiting(among: conversation.current.turns)
			let queued = work.phase.items(queued: work.waiting)
			let overlay = TurnOverlay(
				of: turn, window: work.window, queued: queued.compactMap(\.turn), waiting: waiting)
			let refusal = TurnLifecycle.retryRefusal(
				of: conversation.turn(turn), overlay: overlay, device: ledger.deviceId,
				process: process)
			if let refusal { throw RetryRefusal(refusal) }
			holdLease(.athlete)?.add(turn)
			if work.add(turn, origin: .retry) { workAdded() }
		}
	}

	package func interrupt(_ cause: InterruptionCause) async {
		guard work.phase.cause == nil else { return await work.joinInterruption() }
		guard work.phase.running != nil || work.window != nil || !work.isEmpty || door.held else {
			return
		}
		work.beginInterruption(cause)
		publish()
		work.phase.running?.task.cancel()
		await door.pass {
			await work.phase.running?.task.value
			let unstarted = work.dropWaiting() + [work.closeWindow()].compactMap { $0 }
			for turn in unstarted {
				let stamp = await stamp(for: turn)
				let stopped = TurnLifecycle.stopBeforeStart(
					stamp.attempt, on: conversation.turn(turn), chat: chatId)
				guard case .success(let settled) = stopped else { continue }
				await records.settle(settled, stamp: stamp)
			}
			work.endInterruption()
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
			await door.pass { closeWindow() }
		case .willTerminate:
			let owned = work.phase.cause == nil
			if owned { work.beginInterruption(.appTerminating) }
			publish()
			work.phase.running?.task.cancel()
			await work.phase.running?.task.value
			leases.end { $0.interrupt() }
			if owned { work.endInterruption() }
			publish()
		}
	}

	package func recover(_ plan: RecoveryPlan) async throws(LedgerFailure) {
		try await records.load()
		for dead in plan.interrupt {
			let stamp = OperationStamp.turn(dead.turn, attempt: dead.attempt, clock: clock)
			await records.settle(
				TurnLifecycle.settled(
					dead.attempt,
					.interrupted(partial: "", cause: .processEnded, saved: dead.saved),
					on: conversation.turn(dead.turn), chat: chatId), stamp: stamp)
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

	package func refreshImports() async throws(LedgerFailure) {
		try await records.refresh()
		publish()
	}

	package var reviewScope: TurnScope? {
		work.phase.running?.attempt?.scope
	}

	private func stamp(for turn: TurnID) async -> OperationStamp {
		.turn(turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
	}

	private func closeWindow(ifArmed armed: Int? = nil) {
		guard let turn = work.closeWindow(ifArmed: armed) else { return }
		if work.add(turn, origin: .send) { workAdded() }
	}

	private func armWindow(for turn: TurnID) {
		let armed = work.arm(turn, at: clock.now, for: coalescing.window)
		Task {
			do {
				try await coalescingSleep(coalescing.window)
			} catch is CancellationError {
				return
			} catch {
				fatalError("Coalescing sleep failed: \(error)")
			}
			await door.pass { closeWindow(ifArmed: armed) }
		}
	}

	private func workAdded() {
		publish()
		drainIfIdle()
	}

	private func drainIfIdle() {
		guard case .idle = work.phase, let initiator = work.next?.initiator,
			let lease = holdLease(initiator)
		else { return }
		work.start { next in
			Task {
				switch next {
				case .turn(let turn, let origin):
					await self.runTurn(turn, origin: origin, under: lease)
				case .flush(let job):
					let access = await self.environment.flushAccess()
					await self.flushes.drain(job, in: self.conversation, access: access)
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
	}

	private func workFinished() {
		work.finish()
		if work.isEmpty {
			if work.window == nil, work.phase.cause == nil, !lifetime.terminating {
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

	private func runTurn(_ turn: TurnID, origin: AttemptOrigin, under lease: DrainLease) async {
		guard let facts = conversation.turn(turn) else { return }
		lease.add(turn)
		let resolution = await environment.resolve()
		let stamp = await stamp(for: turn).bound(to: resolution.account)
		guard
			let request = await start.begin(
				facts, origin: origin, resolution: resolution, stamp: stamp, lease: await lease.kind
			)
		else { return finish(turn, under: lease) }
		let attempt = stamp.attempt
		let scope = TurnScope(stamp: stamp, policy: .npm, uptime: clock.uptime)
		work.show(
			RunningAttempt(
				live: LiveAttempt(
					turn: turn, attempt: attempt, text: "", activity: .generating(step: 1)),
				scope: scope))
		publish()
		let settlement: Settlement
		do {
			let result = try await runner.run(
				request, scope: scope,
				committed: { records in
					await self.apply(records)
				}
			) { progress in
				lease.observe(progress)
				await self.apply(progress, turn: turn, stamp: stamp)
			}
			settlement = Settlement(result)
		} catch {
			settlement = .interrupted(
				partial: work.phase.running?.live?.text ?? "",
				cause: work.phase.cause ?? .athleteStopped,
				saved: await scope.interrupt())
		}
		await records.settle(
			TurnLifecycle.settled(attempt, settlement, on: conversation.turn(turn), chat: chatId),
			stamp: stamp)
		finish(turn, under: lease)
		if !lifetime.terminating {
			for job in await records.refreshJobs(from: flushes) {
				if work.add(job) { workAdded() }
			}
		}
	}

	private func finish(_ turn: TurnID, under lease: DrainLease) {
		work.finishTurn()
		let reply = conversation.turn(turn)?.reply
		if reply != nil, !foreground {
			finishedAway.insert(turn)
		}
		lease.settle(turn, reply: reply)
		publish()
	}

	private func apply(_ committed: [AthleteRecord]) {
		records.apply(committed)
		publish()
	}

	private func apply(_ progress: AttemptProgress, turn: TurnID, stamp: OperationStamp) async {
		await records.apply(progress, turn: turn, stamp: stamp)
		work.apply(progress, attempt: stamp.attempt)
		publish()
	}

	private func snapshot() -> ChatSnapshot {
		ChatSnapshot(
			chat: chatId,
			conversation: conversation,
			jobs: records.jobs,
			phase: work.phase,
			window: work.window,
			queued: work.waiting,
			waiting: waits.waiting(among: conversation.current.turns),
			finishedAway: finishedAway,
			review: records.review,
			device: ledger.deviceId,
			process: process,
			now: clock.now, zone: clock.timeZone
		)
	}

	private func publish() {
		feed.publish(snapshot())
	}

	private func waitEnded(_ turn: TurnID, _ attempt: AttemptID) {
		if waits.end(turn, attempt: attempt) { publish() }
	}
}
