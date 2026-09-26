import Foundation

package actor ChatMailbox {
	package let chatId: ChatID
	private let ledger: Ledger
	private let runner: TurnRunner
	private let flushes: FlushWork
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let environment: EnvironmentResolver

	private var loaded = false
	private var loading: Task<Result<Void, LedgerFailure>, Never>?
	private var conversation: Conversation
	private var pendingProposal: PendingProposal?
	private var work: [MailboxWork] = []
	private var active: MailboxWork?
	private var window: OpenWindow?
	private var windowGeneration = 0
	private var live: LiveAttempt?
	private var running: Task<Void, Never>?
	private var stopping: InterruptionCause?
	private var terminating = false
	private let admission = Admission()
	private let feed = SnapshotFeed()

	package init(
		chatId: ChatID,
		ledger: Ledger,
		runner: TurnRunner,
		flushes: FlushWork,
		clock: any Clock,
		coalescing: CoalescingPolicy,
		environment: EnvironmentResolver
	) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.flushes = flushes
		self.clock = clock
		self.coalescing = coalescing
		self.environment = environment
		self.conversation = Conversation(chat: chatId, segments: [])
	}

	package func observe() async -> AsyncStream<ChatSnapshot> {
		await loadShowingWhatStands()
		return feed.subscribe(from: snapshot())
	}

	package func accept(_ draft: Draft) async throws(AcceptFailure) -> SendOutcome {
		let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return .ignoredBlank }
		let slash = SlashRouting.parse(text)
		if slash == .language {
			return .showLanguagePicker
		}
		await admission.enter()
		defer { admission.leave() }
		return try await admit(Draft(id: draft.id, text: text), slash: slash)
	}

	private func admit(_ draft: Draft, slash: SlashCommand?) async throws(AcceptFailure)
		-> SendOutcome
	{
		do {
			try await load()
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		if let known = conversation.turn(withDraft: draft.id) {
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
		guard let facts = conversation.turn(turn) else { throw RetryRefusal.unknownTurn }
		if window?.turn == turn || queuedTurns(includingActive: true).contains(turn) {
			throw RetryRefusal.alreadyRunning
		}
		if let refusal = TurnLifecycle.claimRefusal(of: facts, device: ledger.deviceId) {
			throw RetryRefusal(refusal)
		}
		enqueue(.turn(turn))
	}

	package func stop() async {
		let active = running
		guard active != nil || window != nil || !queuedTurns(includingActive: false).isEmpty
		else { return }
		stopping = .athleteStopped
		publish()
		active?.cancel()
		await admission.enter()
		let unstarted = queuedTurns(includingActive: false) + [window?.turn].compactMap { $0 }
		window = nil
		work.removeAll { $0.turn != nil }
		for turn in unstarted {
			let stamp = await stamp(for: turn)
			await settle(turn, .stopBeforeStart(stamp.attempt), stamp: stamp)
		}
		admission.leave()
		await active?.value
		stopping = nil
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
			stopping = .appTerminating
			running?.cancel()
			await running?.value
			stopping = nil
			publish()
		}
	}

	package func recover(_ plan: RecoveryPlan) async {
		await loadShowingWhatStands()
		for dead in plan.interrupt {
			let stamp = OperationStamp.turn(dead.turn, attempt: dead.attempt, clock: clock)
			await settle(
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
			pendingProposal = try await ProposalPolicy.pending(chatId, in: ledger, now: clock.now)
		} catch {
			pendingProposal = nil
		}
		publish()
	}

	private func loadShowingWhatStands() async {
		do {
			try await load()
		} catch {
			switch error {
			case .unavailable, .rejectedBatch:
				break
			}
		}
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
			pendingProposal = try await ProposalPolicy.pending(chatId, in: ledger, now: clock.now)
			conversation = folded
			loaded = true
			return .success(())
		} catch {
			return .failure(error)
		}
	}

	private func stamp(for turn: TurnID) async -> OperationStamp {
		.turn(turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
	}

	private func commit(_ writes: TurnWrites, stamp: OperationStamp) async throws(LedgerFailure) {
		let records = try await ledger.commit(writes, stamp: stamp)
		conversation = ConversationFold.applying(records, to: conversation, device: ledger.deviceId)
	}

	private func armWindow(for turn: TurnID) {
		windowGeneration += 1
		let generation = windowGeneration
		let duration = coalescing.window
		window = OpenWindow(
			turn: turn, closesAt: clock.now.addingTimeInterval(duration.timeInterval))
		Task {
			do {
				try await Task.sleep(for: duration)
			} catch is CancellationError {
				return
			} catch {
				fatalError("Task.sleep failed: \(error)")
			}
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
		guard running == nil, stopping == nil, !terminating, !work.isEmpty else { return }
		let next = work.removeFirst()
		active = next
		running = Task {
			switch next {
			case .turn(let turn):
				await self.runTurn(turn)
			case .flush(let job):
				await self.flushes.drain(
					job, in: self.conversation, access: self.environment.access)
			}
			self.running = nil
			self.active = nil
			self.drainIfIdle()
			self.publish()
		}
	}

	private func runTurn(_ turn: TurnID) async {
		guard let facts = conversation.turn(turn) else { return }
		let stamp = await stamp(for: turn)
		let attempt = stamp.attempt
		guard case .success(let claim) = writes(.claim(attempt), for: turn) else {
			publish()
			return
		}
		do {
			try await commit(claim, stamp: stamp)
		} catch {
			await settleUnsaved(
				turn, attempt: attempt, .failed(.local(.recordStorage), saved: .none))
			publish()
			return
		}
		let access: ResolvedAccess
		do {
			access = try environment.access()
		} catch {
			let unavailable = Settlement.failed(.model(.accessUnavailable(error)), saved: .none)
			await settle(turn, .settle(attempt, unavailable), stamp: stamp)
			publish()
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
				await self.apply(progress, turn: turn, stamp: stamp)
			}
			settlement = Settlement(result)
		} catch {
			settlement = .interrupted(
				partial: live?.text ?? "", cause: stopping ?? .athleteStopped,
				saved: await scope.summary)
		}
		await settle(turn, .settle(attempt, settlement), stamp: stamp)
		live = nil
		if !terminating {
			for job in await flushes.pending() {
				enqueue(.flush(job))
			}
		}
		publish()
	}

	private func writes(_ event: TurnEvent, for turn: TurnID) -> Result<TurnWrites, TurnRefusal> {
		TurnLifecycle.writes(
			for: event, on: conversation.turn(turn), chat: chatId, device: ledger.deviceId,
			mint: { turn })
	}

	private func settle(_ turn: TurnID, _ event: TurnEvent, stamp: OperationStamp) async {
		guard case .success(let planned) = writes(event, for: turn),
			case .synced(let bodies) = planned, case .turnSettled(let settled)? = bodies.first
		else {
			return
		}
		do {
			try await commit(planned, stamp: stamp)
			if active == .turn(turn) { active = nil }
		} catch {
			await settleUnsaved(turn, attempt: settled.attempt, settled.settlement)
		}
	}

	private func settleUnsaved(_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement) async {
		let ulid = await ledger.nextULID()
		conversation.settleInMemory(
			turn, attempt: attempt, settlement, ulid: ulid, now: clock.now, zone: clock.timeZone,
			device: ledger.deviceId)
		if active == .turn(turn) { active = nil }
	}

	private func apply(_ progress: AttemptProgress, turn: TurnID, stamp: OperationStamp) async {
		if case .textDelta(let delta) = progress, !delta.isEmpty,
			case .success(let mark) = writes(.observeReply(stamp.attempt), for: turn)
		{
			do {
				try await commit(mark, stamp: stamp)
			} catch {
				conversation.observeInMemory(turn, attempt: stamp.attempt)
				ledger.report(.replyObservedUnsaved(stamp.attempt, detail: "\(error)"))
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
			chat: chatId,
			conversation: conversation,
			live: live,
			window: window,
			queued: queuedTurns(includingActive: true),
			stopping: stopping != nil,
			pendingProposal: pendingProposal,
			device: ledger.deviceId,
			now: clock.now,
			zone: clock.timeZone
		)
	}

	private func publish() {
		feed.publish(snapshot())
	}
}
