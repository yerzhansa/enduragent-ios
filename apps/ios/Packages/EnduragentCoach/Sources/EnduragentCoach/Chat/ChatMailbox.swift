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
	private lazy var work = MailboxExecution(
		chat: chatId, ledger: ledger, runner: runner, flushes: flushes, clock: clock,
		environment: environment, process: process, records: records, lifecycle: lifecycle)
	private let door = Turnstile()
	private let lifecycle: MailboxLifecycle
	private let feed: SnapshotFeed<ChatSnapshot>
	private lazy var snapshots = MailboxSnapshots(
		chat: chatId, device: ledger.deviceId, process: process, clock: clock, feed: feed
	) { [weak self] in
		await self?.waitEnded($0, $1)
	}

	init(
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
		host: any ExecutionHost, lifetime: Coach.Lifetime, feed: SnapshotFeed<ChatSnapshot>,
		recoveryRecords: [AthleteRecord]?
	) async throws(LedgerFailure) {
		self.chatId = chatId
		self.ledger = ledger
		self.runner = runner
		self.flushes = flushes
		self.clock = clock
		self.coalescing = coalescing
		self.coalescingSleep = coalescingSleep
		self.environment = environment
		self.process = process
		self.feed = feed
		self.lifecycle = MailboxLifecycle(host: host, chat: chatId, lifetime: lifetime) {
			await environment.appLanguage()
		}
		self.records = ChatRecords(chat: chatId, ledger: ledger, clock: clock, reviews: reviews)
		try await records.refresh(recoveryRecords: recoveryRecords)
		publish()
	}

	var conversation: Conversation { records.conversation }
	var jobs: [FlushJob] { records.jobs }

	package func hasLocalWork() async throws(LedgerFailure) -> Bool {
		let stored = try await ledger.hasLocalWork(in: chatId, now: clock.now)
		return await records.hasLocalWork() || stored || work.phase.running != nil
			|| work.phase.cause != nil
			|| work.window != nil || !work.isEmpty || door.held
	}

	package func observe() async -> AsyncStream<ChatSnapshot> {
		snapshots.observe(snapshotInput)
	}

	package func accept(_ draft: Draft, slash: SlashCommand?) async throws(AcceptFailure)
		-> SendOutcome
	{
		return try await door.pass { () throws(AcceptFailure) in
			try await admit(draft, slash: slash)
		}
	}

	package func reset() async -> ResetAdmission {
		do {
			let reset = try await door.pass { () throws(LedgerFailure) in
				guard !lifecycle.terminating else { throw LedgerFailure.unavailable }
				closeWindow()
				let reset = try await ledger.reserveReset()
				guard !lifecycle.terminating else { throw LedgerFailure.unavailable }
				_ = lifecycle.hold(.athlete, on: self)
				work.add(reset, on: self)
				return reset
			}
			return .accepted(reset.id)
		} catch {
			return .notStarted(.local(.recordStorage))
		}
	}

	private func admit(
		_ draft: Draft, slash: SlashCommand?
	) async throws(AcceptFailure) -> SendOutcome {
		guard !lifecycle.terminating else { throw .storageUnavailable }
		if let known = conversation.turn(withDraft: draft.id) {
			return .accepted(known.turn)
		}
		let turn: TurnID
		let fragment: Int
		if let window = work.window, slash == nil,
			let facts = conversation.current.turns.first(where: { $0.turn == window.turn })
		{
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
			await records.retrySettlements()
			records.apply(try await ledger.commit(synced: [.userMessage(message)], stamp: stamp))
		} catch {
			throw AcceptFailure.storageUnavailable
		}
		lifecycle.hold(.athlete, on: self)?.add(turn)
		work.schedule(turn, policy: coalescing, sleep: coalescingSleep, on: self)
		publish()
		return .accepted(turn)
	}

	package func retry(_ turn: TurnID) async throws(RetryRefusal) {
		try await door.pass { () throws(RetryRefusal) in
			guard !lifecycle.terminating else { throw .unrecovered }
			let waiting = snapshots.waiting(among: conversation.current.turns)
			let queued = work.phase.items(queued: work.waiting)
			let overlay = TurnOverlay(
				of: turn, window: work.window, queued: queued.compactMap(\.turn), waiting: waiting)
			let refusal = TurnLifecycle.retryRefusal(
				of: conversation.turn(turn), overlay: overlay, device: ledger.deviceId,
				process: process)
			if let refusal { throw RetryRefusal(refusal) }
			lifecycle.hold(.athlete, on: self)?.add(turn)
			work.add(turn, origin: .retry, on: self)
		}
	}

	package func cancelInFlight(cause: InterruptionCause) async {
		await lifecycle.cancelInFlight(
			cause: cause, work: work, records: records, door: door, on: self)
	}

	package func enteredBackground() async {
		await door.pass { closeWindow() }
	}

	package func recover(_ plan: RecoveryPlan) async {
		await lifecycle.recover(plan, records: records, work: work, on: self)
	}

	package func refreshLeaseTitle() async {
		await lifecycle.updateLanguage(await environment.appLanguage())
	}

	package var reviewReadUnavailable: Bool { records.review?.notice?.kind == .storageUnavailable }

	package func reviewChanged(_ ref: ReviewRef? = nil) async -> ReviewOutcome {
		defer { publish() }
		return await records.refreshReview(ref)
	}

	package func decide(_ decision: ReviewDecision) async -> ReviewOutcome {
		defer { publish() }
		return await records.decide(decision, scope: reviewScope) { () throws(LedgerFailure) in
			try await self.updateReview()
		}
	}

	private func updateReview() async throws(LedgerFailure) {
		defer { publish() }
		try await records.updateReview()
	}

	package func refreshImports() async throws(LedgerFailure) {
		defer { publish() }
		try await records.refresh()
		work.reconcileResets(on: self)
		if let window = work.window,
			!conversation.current.turns.contains(where: { $0.turn == window.turn })
		{
			closeWindow()
		}
	}

	package var reviewScope: TurnScope? { work.phase.running?.attempt?.scope }

	func stamp(for turn: TurnID) async -> OperationStamp {
		.turn(turn, attempt: AttemptID(ulid: await ledger.nextULID()), clock: clock)
	}

	private func closeWindow(ifArmed armed: Int? = nil) {
		guard !lifecycle.terminating, let turn = work.closeWindow(ifArmed: armed) else { return }
		work.add(turn, origin: .send, on: self)
	}

	func windowEnded(_ armed: Int) async throws(CancellationError) {
		try await door.passCancellable(cancellation: CancellationError()) {
			() throws(CancellationError) in
			closeWindow(ifArmed: armed)
		}
	}

	func expire(_ cause: ExpiryCause, lease generation: Int) async {
		await lifecycle.expire(cause, lease: generation, on: self)
	}

	func apply(_ committed: [AthleteRecord]) {
		work.apply(committed, on: self)
	}

	func apply(_ progress: AttemptProgress, turn: TurnID, stamp: OperationStamp) async {
		await work.apply(progress, turn: turn, stamp: stamp, on: self)
	}

	private var snapshotInput: MailboxSnapshotInput {
		MailboxSnapshotInput(
			conversation: conversation, jobs: records.jobs, phase: work.phase,
			window: work.window, queued: work.waiting, finishedAway: lifecycle.finishedAway,
			unsavedTurns: records.unsavedTurns, review: records.review,
			reset: work.resetStatus, resetMemory: work.resetMemory)
	}

	func publish(liveText: Bool = false) {
		snapshots.publish(snapshotInput, liveText: liveText, live: work.phase.running?.live)
	}

	private func waitEnded(_ turn: TurnID, _ attempt: AttemptID) {
		if snapshots.waitEnded(turn, attempt) { publish() }
	}
}
