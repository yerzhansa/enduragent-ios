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

	private var loaded = false
	private var conversation: Conversation
	private var pendingProposal: PendingProposal?
	private var work: [MailboxWork] = []
	private var active: MailboxWork?
	private var window: OpenWindow?
	private var windowGeneration = 0
	private var live: LiveAttempt?
	private var running: Task<Void, Never>?
	private var stopping = false
	private var observers: [UUID: AsyncStream<ChatSnapshot>.Continuation] = [:]

	package init(
		chatId: ChatID,
		ledger: Ledger,
		runner: TurnRunner,
		memory: Memory,
		transport: any ModelTransport,
		clock: any Clock,
		coalescing: CoalescingPolicy,
		environment: EnvironmentResolver
	) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.memory = memory
		self.transport = transport
		self.clock = clock
		self.coalescing = coalescing
		self.environment = environment
		self.conversation = Conversation(chat: chatId, segments: [])
	}

	package func observe() async -> AsyncStream<ChatSnapshot> {
		await loadIfNeeded()
		let id = UUID()
		let (stream, continuation) = AsyncStream<ChatSnapshot>.makeStream(
			bufferingPolicy: .unbounded)
		observers[id] = continuation
		continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
		continuation.yield(snapshot())
		return stream
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
		guard let running else { return }
		stopping = true
		publish()
		let queued = queuedTurns(includingActive: false)
		work.removeAll { if case .turn = $0 { true } else { false } }
		for turn in queued {
			let stamp = await stamp(for: turn)
			await settle(
				turn, attempt: stamp.attempt,
				.interrupted(partial: "", cause: .stoppedBeforeStart, saved: .none),
				stamp: stamp, beforeStart: true)
		}
		running.cancel()
		await running.value
		stopping = false
		publish()
	}

	private func queuedTurns(includingActive: Bool) -> [TurnID] {
		let items = includingActive ? [active].compactMap { $0 } + work : work
		return items.compactMap { item -> TurnID? in
			if case .turn(let turn) = item { return turn }
			return nil
		}
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

	private func stamp(for turn: TurnID) async -> OperationStamp {
		OperationStamp(
			operation: .turn(turn),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
	}

	private func commit(_ writes: TurnWrites, stamp: OperationStamp) async throws(LedgerFailure) {
		let records: [AthleteRecord]
		switch writes {
		case .nothing:
			return
		case .synced(let bodies):
			records = try await ledger.commit(synced: bodies, stamp: stamp)
		case .local(let bodies):
			records = try await ledger.commit(local: bodies, stamp: stamp)
		}
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
		guard running == nil, !work.isEmpty else { return }
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
		live = LiveAttempt(turn: turn, attempt: attempt, text: "", activity: .generating(step: 1))
		publish()
		let request = TurnAttempt(
			turn: turn, attempt: attempt, chat: chatId, request: facts.requestText,
			slash: facts.slash, language: await environment.language())
		let settlement: Settlement
		var softFlushDue = false
		do {
			let report = try await runner.run(request) { progress in
				await self.apply(progress, attempt: attempt)
			}
			settlement = Settlement(report.result)
			softFlushDue = report.softFlushDue
		} catch {
			settlement = .interrupted(
				partial: live?.text ?? "", cause: .athleteStopped, saved: .none)
		}
		await settle(turn, attempt: attempt, settlement, stamp: stamp)
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

	private func settle(
		_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement, stamp: OperationStamp,
		beforeStart: Bool = false
	) async {
		let event: TurnEvent =
			beforeStart ? .stopBeforeStart(attempt) : .settle(attempt, settlement)
		guard case .success(let writes) = writes(event, for: turn) else { return }
		do {
			try await commit(writes, stamp: stamp)
		} catch {
			await settleUnsaved(turn, attempt: attempt, settlement)
		}
	}

	private func settleUnsaved(_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement) async {
		guard let facts = conversation.turn(turn) else { return }
		let last = (facts.fragments.map(\.hlc) + facts.settlements.map(\.hlc)).max()
		let settled = SettledAttempt(
			ulid: await ledger.nextULID(),
			hlc: HybridLogicalClock.tick(now: clock.now, deviceId: ledger.deviceId, last: last),
			civilDate: CivilDate(date: clock.now, timeZone: clock.timeZone),
			attempt: attempt,
			settlement: settlement
		)
		conversation.settle(turn, with: settled)
	}

	private func drainFlush() async {
		try? await self.memory.flush(
			trigger: .softThreshold,
			chatId: self.chatId,
			transport: self.transport
		)
	}

	private func apply(_ progress: AttemptProgress, attempt: AttemptID) {
		guard var current = live, current.attempt == attempt else { return }
		switch progress {
		case .textDelta(let delta):
			current.text += delta
		case .attemptRestarted:
			current.text = ""
		case .activity(let activity):
			current.activity = activity
		case .proposalPending(let proposal):
			pendingProposal = proposal
		}
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
			stopping: stopping,
			pendingProposal: pendingProposal,
			device: ledger.deviceId,
			now: clock.now,
			zone: clock.timeZone
		)
	}

	private func publish() {
		let current = snapshot()
		for continuation in observers.values {
			continuation.yield(current)
		}
	}

	private func removeObserver(_ id: UUID) {
		observers[id] = nil
	}
}
