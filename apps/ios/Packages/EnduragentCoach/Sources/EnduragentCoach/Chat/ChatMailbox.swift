import Foundation

package actor ChatMailbox {
	package let chatId: ChatID
	private let ledger: Ledger
	private let runner: TurnRunner
	private let memory: Memory
	private let transport: any ModelTransport
	private let clock: any Clock
	private let coalescing: CoalescingPolicy
	private let environment: EnvironmentResolver
	private let diagnostics: DiagnosticsLog

	private var loaded = false
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
		diagnostics: DiagnosticsLog
	) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.memory = memory
		self.transport = transport
		self.clock = clock
		self.coalescing = coalescing
		self.environment = environment
		self.diagnostics = diagnostics
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
		if let window, slash == nil {
			joining = window.turn
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
		armWindow(for: message.turn)
		publish()
		return .accepted(message.turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		await loadIfNeeded()
		guard let facts = conversation.turn(turn) else { throw RetryRefusal.unknownTurn }
		if live?.turn == turn || window?.turn == turn || work.contains(.turn(turn)) {
			throw RetryRefusal.alreadyRunning
		}
		if let refusal = TurnLifecycle.claimRefusal(of: facts, device: ledger.deviceId) {
			throw RetryRefusal(refusal)
		}
		enqueue(.turn(turn))
	}

	package func stop() async {
		guard running != nil else { return }
		stopping = .athleteStopped
		publish()
		let queued = queuedTurns(includingActive: false)
		work.removeAll { $0.turn != nil }
		for turn in queued {
			let stamp = await stamp(for: turn)
			await settle(turn, .stopBeforeStart(stamp.attempt), stamp: stamp)
		}
		await cancelRunning()
	}

	package func lifecycle(_ event: AppLifecycleEvent) async {
		switch event {
		case .becameActive, .willResignActive:
			return
		case .enteredBackground:
			closeWindow()
		case .willTerminate:
			terminating = true
			stopping = .appTerminating
			await cancelRunning()
		}
	}

	package func recover(_ plan: RecoveryPlan) async {
		await loadIfNeeded()
		for dead in plan.interrupt {
			let stamp = await stamp(for: dead.turn, attempt: dead.attempt)
			await settle(
				dead.turn, .recoverDeadClaim(dead.attempt, saved: dead.saved), stamp: stamp)
		}
		publish()
	}

	private func cancelRunning() async {
		if let running {
			running.cancel()
			await running.value
		}
		stopping = nil
		publish()
	}

	private func queuedTurns(includingActive: Bool) -> [TurnID] {
		let items = includingActive ? [active].compactMap { $0 } + work : work
		return items.compactMap(\.turn)
	}

	package func refreshProposal() async {
		do {
			try await loadProposal()
		} catch {
			pendingProposal = nil
		}
		publish()
	}

	package func flushAndDrain() async {
		enqueue(.flush)
		while let task = running {
			await task.value
		}
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
		let synced = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chatId))
		let local = try await ledger.read(
			RecordQuery(scope: ConversationFold.localScope, chatId: chatId))
		conversation = ConversationFold.fold(
			chat: chatId, synced: synced.records, local: local.records, device: ledger.deviceId)
		try await loadProposal()
		loaded = true
	}

	private func loadProposal() async throws(LedgerFailure) {
		let records = try await ledger.read(ProposalPolicy.proposalQuery(chatId)).records
		pendingProposal = UnionMerge.pendingProposal(records, chatId: chatId, now: clock.now)
			.map(PendingProposal.init)
	}

	private func stamp(for turn: TurnID, attempt known: AttemptID? = nil) async -> OperationStamp {
		let zone = AthleteCalendar(clock: clock).deviceZone
		let attempt = if let known { known } else { AttemptID(ulid: await ledger.nextULID()) }
		return OperationStamp(
			operation: .turn(turn), attempt: attempt,
			binding: ActionBinding(account: .unconnected, zone: zone))
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
			self.closeWindow(ifGeneration: generation)
		}
	}

	private func closeWindow(ifGeneration generation: Int? = nil) {
		guard let window, generation == nil || generation == windowGeneration else { return }
		self.window = nil
		enqueue(.turn(window.turn))
	}

	private func enqueue(_ item: MailboxWork) {
		work.append(item)
		publish()
		drainIfIdle()
	}

	private func drainIfIdle() {
		guard running == nil, !terminating, !work.isEmpty else { return }
		let next = work.removeFirst()
		active = next
		running = Task {
			switch next {
			case .turn(let turn):
				await self.runTurn(turn)
			case .flush:
				await self.drainFlush()
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
			await settle(
				turn, .settle(attempt, .failed(.model(.accessUnavailable(error)), saved: .none)),
				stamp: stamp)
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
		var softFlushDue = false
		do {
			let report = try await runner.run(request, scope: scope) { progress in
				await self.apply(progress, stamp: stamp)
			}
			settlement = Settlement(report.result)
			softFlushDue = report.softFlushDue
		} catch {
			settlement = .interrupted(
				partial: live?.text ?? "", cause: stopping ?? .athleteStopped,
				saved: WriteSummary(await scope.written))
		}
		await settle(turn, .settle(attempt, settlement), stamp: stamp)
		live = nil
		if softFlushDue {
			work.append(.flush)
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
		} catch {
			await settleUnsaved(turn, attempt: settled.attempt, settled.settlement)
		}
	}

	private func settleUnsaved(_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement) async {
		let ulid = await ledger.nextULID()
		conversation.settleUnsaved(
			turn, attempt: attempt, settlement, ulid: ulid, device: ledger.deviceId, clock: clock)
	}

	private func drainFlush() async {
		do {
			let access = try environment.access()
			try await memory.flush(
				trigger: .softThreshold, chatId: chatId, transport: transport, access: access)
		} catch is CancellationError {
		} catch {
			diagnostics.record(.memoryFlushFailed(chatId, detail: String(describing: error)))
		}
	}

	private func apply(_ progress: AttemptProgress, stamp: OperationStamp) async {
		guard let observing = live, observing.attempt == stamp.attempt else { return }
		if case .textDelta(let delta) = progress, !delta.isEmpty,
			case .success(let mark) = writes(.observeReply(stamp.attempt), for: observing.turn)
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
