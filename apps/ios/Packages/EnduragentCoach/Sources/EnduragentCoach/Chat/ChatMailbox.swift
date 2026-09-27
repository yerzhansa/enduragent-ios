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
	private var jobs: [FlushJob] = []
	private lazy var resets = PendingResets(
		ConversationReset(chat: chatId, ledger: ledger, flushes: flushes, clock: clock))
	private lazy var start = AttemptStart(
		chat: chatId, records: records, environment: environment, process: process)
	private var work: [MailboxWork] = []
	private var active: MailboxWork?
	private var window: OpenWindow?
	private var windowGeneration = 0
	private var live: LiveAttempt?
	private var running: Task<Void, Never>?
	private var interruption: InterruptionCause?
	private var terminating = false
	private let admission = Admission()
	private lazy var waits = RetryWaits(clock: clock) { [weak self] in
		await self?.waitEnded($0, $1)
	}
	private let feed = SnapshotFeed<ChatSnapshot>()

	package init(
		chatId: ChatID,
		ledger: Ledger,
		runner: TurnRunner,
		flushes: FlushWork,
		clock: any Clock,
		coalescing: CoalescingPolicy,
		environment: EnvironmentResolver,
		process: ProcessID
	) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.flushes = flushes
		self.clock = clock
		self.coalescing = coalescing
		self.environment = environment
		self.process = process
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
			try await load()
		} catch {
			admission.leave()
			return .notStarted(.local(.recordStorage))
		}
		closeWindow()
		let reset = ResetID(ulid: await ledger.nextULID())
		return await resets.outcome(of: reset) {
			enqueue(.reset(reset))
			admission.leave()
		}
	}

	private func admit(_ draft: Draft, slash: SlashCommand?) async throws(AcceptFailure)
		-> SendOutcome
	{
		do {
			try await load()
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		if let known = records.conversation.turn(withDraft: draft.id) {
			return .accepted(known.turn)
		}
		let joining: TurnID?
		if let window, slash == nil {
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
		armWindow(for: message.turn)
		publish()
		return .accepted(message.turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		do {
			try await load()
		} catch {
			throw RetryRefusal.unknownTurn
		}
		let waiting = waits.waiting(among: records.conversation.current.turns)
		let queued = queuedTurns(includingActive: true)
		let overlay = TurnOverlay(of: turn, window: window, queued: queued, waiting: waiting)
		let refusal = TurnLifecycle.retryRefusal(
			of: records.conversation.turn(turn), overlay: overlay, device: ledger.deviceId,
			process: process)
		if let refusal { throw RetryRefusal(refusal) }
		enqueue(.turn(turn))
	}

	package func stop() async {
		let active = running
		guard active != nil || window != nil || !queuedTurns(includingActive: false).isEmpty
		else { return }
		interruption = .athleteStopped
		publish()
		active?.cancel()
		await admission.enter()
		let unstarted = queuedTurns(includingActive: false) + [window?.turn].compactMap { $0 }
		window = nil
		work.removeAll { $0.turn != nil }
		for turn in unstarted {
			let stamp = await stamp(for: turn)
			await records.settle(turn, .stopBeforeStart(stamp.attempt), stamp: stamp)
		}
		admission.leave()
		await active?.value
		interruption = nil
		publish()
		drainIfIdle()
	}

	package func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive, .willResignActive:
			return
		case .enteredBackground:
			await admission.enter()
			closeWindow()
			admission.leave()
		case .willTerminate:
			terminating = true
			let active = running
			interruption = .appTerminating
			active?.cancel()
			await active?.value
			interruption = nil
			publish()
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
			enqueue(.flush(job))
		}
		publish()
	}

	private func queuedTurns(includingActive: Bool) -> [TurnID] {
		let items = includingActive ? [active].compactMap { $0 } + work : work
		return items.compactMap(\.turn)
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
			jobs = try await ledger.flushJobs(in: chatId)
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

	private func armWindow(for turn: TurnID) {
		windowGeneration += 1
		let generation = windowGeneration
		window = OpenWindow(
			turn: turn, closesAt: clock.now.addingTimeInterval(coalescing.window.timeInterval))
		Task {
			guard await coalescing.windowElapsed() else { return }
			await self.admission.enter()
			self.closeWindow(ifGeneration: generation)
			self.admission.leave()
		}
	}

	private func closeWindow(ifGeneration generation: Int? = nil) {
		guard let window, generation == nil || generation == windowGeneration else { return }
		self.window = nil
		enqueue(.turn(window.turn))
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
		active = next
		running = Task {
			switch next {
			case .turn(let turn):
				await self.runTurn(turn)
			case .flush(let job):
				await self.flushes.drain(
					job, in: self.records.conversation, access: await self.environment.flushAccess()
				)
				self.jobs = await self.flushes.jobs()
			case .reset(let reset):
				await self.resets.run(
					reset, on: self.records, access: await self.environment.flushAccess())
				self.jobs = await self.flushes.jobs()
				self.publish()
			}
			self.workFinished()
		}
	}

	private func workFinished() {
		running = nil
		active = nil
		if work.isEmpty {
			publish()
		} else {
			drainIfIdle()
		}
	}

	private func runTurn(_ turn: TurnID) async {
		guard let facts = records.conversation.turn(turn) else { return }
		let stamp = await stamp(for: turn)
		guard let request = await start.begin(facts, stamp: stamp) else {
			publish()
			return
		}
		let attempt = stamp.attempt
		live = LiveAttempt(turn: turn, attempt: attempt, text: "", activity: .generating(step: 1))
		publish()
		let scope = TurnScope(stamp: stamp, policy: .npm, uptime: clock.uptime)
		let settlement: Settlement
		do {
			let result = try await runner.run(request, scope: scope) { progress in
				await self.apply(progress, turn: turn, stamp: stamp)
			}
			settlement = Settlement(result)
		} catch {
			settlement = .interrupted(
				partial: live?.text ?? "", cause: interruption ?? .athleteStopped,
				saved: await scope.summary)
		}
		await records.settle(turn, .settle(attempt, settlement), stamp: stamp)
		live = nil
		active = nil
		if !terminating {
			jobs = await flushes.jobs()
			for job in jobs where !job.settled {
				enqueue(.flush(job.id))
			}
		}
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
			jobs: jobs,
			live: live,
			window: window,
			queued: queuedTurns(includingActive: true),
			waiting: waits.waiting(among: records.conversation.current.turns),
			stopping: interruption != nil,
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
