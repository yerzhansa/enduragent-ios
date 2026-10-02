import Foundation

final class MailboxExecution {
	private let chatId: ChatID
	private let runner: TurnRunner
	private let flushes: FlushWork
	private let clock: any Clock
	private let environment: EnvironmentResolver
	private let records: ChatRecords
	private let lifecycle: MailboxLifecycle
	private let start: AttemptStart
	private let resets: MailboxResets
	private let work = MailboxQueue()
	private var coalescingTask: Task<Void, Never>?

	init(
		chat: ChatID, ledger: Ledger, runner: TurnRunner, flushes: FlushWork,
		clock: any Clock, environment: EnvironmentResolver, process: ProcessID,
		records: ChatRecords, lifecycle: MailboxLifecycle
	) {
		self.chatId = chat
		self.runner = runner
		self.flushes = flushes
		self.clock = clock
		self.environment = environment
		self.records = records
		self.lifecycle = lifecycle
		self.start = AttemptStart(
			chat: chat, ledger: ledger, records: records, environment: environment, process: process
		)
		self.resets = MailboxResets(
			ConversationReset(chat: chat, ledger: ledger, flushes: flushes, clock: clock))
	}

	var phase: MailboxPhase { work.phase }
	var window: OpenWindow? { work.window }
	var waiting: [MailboxWork] { work.waiting }
	var isEmpty: Bool { work.isEmpty }

	func add(_ turn: TurnID, origin: AttemptOrigin, on mailbox: isolated ChatMailbox) {
		if work.add(turn, origin: origin) { workAdded(on: mailbox) }
	}

	func add(_ reset: ReservedReset, on mailbox: isolated ChatMailbox) {
		resets.admit(reset)
		if work.add(reset) { workAdded(on: mailbox) }
	}

	func add(_ job: FlushJobID, on mailbox: isolated ChatMailbox) {
		if work.add(job) { workAdded(on: mailbox) }
	}

	var resetStatus: ResetStatus { resets.status }
	var resetMemory: MemorySaveResult? {
		guard case .reset(let reset) = records.conversation.current.openedBy else { return nil }
		return resets.memory(for: reset)
	}

	func reconcileResets(on mailbox: isolated ChatMailbox) {
		resets.reconcile(records.conversation)
	}

	func schedule(
		_ turn: TurnID, policy: CoalescingPolicy,
		sleep: @escaping @Sendable (Duration) async throws -> Void, on mailbox: isolated ChatMailbox
	) {
		if let cause = work.phase.cause {
			if cause != .appTerminating, work.window?.turn != turn {
				add(turn, origin: .send, on: mailbox)
			}
			return
		}
		guard !lifecycle.terminating else { return }
		coalescingTask?.cancel()
		let armed = work.arm(turn, at: clock.now, for: policy.window)
		coalescingTask = Task { [weak mailbox] in
			do {
				try await sleep(policy.window)
				try await mailbox?.windowEnded(armed)
			} catch is CancellationError {
				return
			} catch {
				fatalError("Coalescing sleep failed: \(error)")
			}
		}
	}

	func closeWindow(ifArmed generation: Int? = nil) -> TurnID? {
		guard let turn = work.closeWindow(ifArmed: generation) else { return nil }
		coalescingTask?.cancel()
		coalescingTask = nil
		return turn
	}

	func cancelCoalescing(isolation: isolated (any Actor)? = #isolation) async {
		let task = coalescingTask
		coalescingTask = nil
		task?.cancel()
		await task?.value
	}

	func beginInterruption(_ cause: InterruptionCause) { work.beginInterruption(cause) }

	func joinInterruption(isolation: isolated (any Actor)? = #isolation) async {
		await work.joinInterruption()
	}

	func endInterruption() { work.endInterruption() }

	func dropWaiting() -> [TurnID] { work.dropWaiting() }

	private func workAdded(on mailbox: isolated ChatMailbox) {
		mailbox.publish()
		drainIfIdle(on: mailbox)
	}

	func drainIfIdle(on mailbox: isolated ChatMailbox) {
		guard case .idle = work.phase, let initiator = work.next?.initiator,
			let lease = lifecycle.hold(initiator, on: mailbox)
		else { return }
		work.start { next in
			Task {
				switch next {
				case .turn(let turn, let origin):
					await self.runTurn(turn, origin: origin, under: lease, on: mailbox)
				case .flush(let job):
					let access = await self.environment.flushAccess()
					await self.flushes.drain(job, in: self.records.conversation, access: access)
					_ = await self.records.refreshJobs(from: self.flushes)
				case .reset(let reset):
					let access = await self.environment.flushAccess()
					await self.resets.run(reset, on: self.records, access: access) {
						mailbox.publish()
					}
				}
				self.workFinished(on: mailbox)
			}
		}
	}

	private func workFinished(on mailbox: isolated ChatMailbox) {
		work.finish()
		if work.isEmpty {
			lifecycle.finishDrain(window: work.window, cause: work.phase.cause)
			mailbox.publish()
		} else {
			drainIfIdle(on: mailbox)
		}
	}

	private func runTurn(
		_ turn: TurnID, origin: AttemptOrigin, under lease: DrainLease,
		on mailbox: isolated ChatMailbox
	) async {
		guard let facts = records.conversation.turn(turn) else { return }
		lease.add(turn)
		let resolution = await environment.resolve()
		let stamp = await mailbox.stamp(for: turn).bound(to: resolution.account)
		guard
			let request = await start.begin(
				facts, origin: origin, resolution: resolution, stamp: stamp, lease: await lease.kind
			)
		else { return finish(turn, under: lease, on: mailbox) }
		let attempt = stamp.attempt
		let scope = TurnScope(
			stamp: stamp, policy: .npm, ladder: runner.ladder, uptime: clock.uptime)
		work.show(
			RunningAttempt(
				live: LiveAttempt(
					turn: turn, attempt: attempt, text: "", activity: .generating(step: 1)),
				scope: scope))
		mailbox.publish()
		let settlement: Settlement
		do {
			let result = try await runner.run(
				request, conversation: records.conversation, jobs: records.jobs, scope: scope,
				committed: { records in
					await mailbox.apply(records)
				}
			) { progress in
				lease.observe(progress)
				await mailbox.apply(progress, turn: turn, stamp: stamp)
			}
			settlement = Settlement(result)
		} catch {
			settlement = .interrupted(
				partial: work.phase.running?.live?.text ?? "",
				cause: work.phase.cause ?? .athleteStopped,
				saved: await scope.interrupt())
		}
		await records.settle(
			TurnLifecycle.settled(
				attempt, settlement, on: records.conversation.turn(turn), chat: chatId),
			stamp: stamp)
		finish(turn, under: lease, on: mailbox)
		if !lifecycle.terminating {
			for job in await records.refreshJobs(from: flushes) {
				add(job, on: mailbox)
			}
		}
	}

	private func finish(_ turn: TurnID, under lease: DrainLease, on mailbox: isolated ChatMailbox) {
		work.finishTurn()
		let reply = records.conversation.turn(turn)?.reply
		lifecycle.finish(turn, reply: reply, under: lease)
		mailbox.publish()
	}

	func apply(_ committed: [AthleteRecord], on mailbox: isolated ChatMailbox) {
		records.apply(committed)
		mailbox.publish()
	}

	func apply(
		_ progress: AttemptProgress, turn: TurnID, stamp: OperationStamp,
		on mailbox: isolated ChatMailbox
	) async {
		await records.apply(progress, turn: turn, stamp: stamp)
		work.apply(progress, attempt: stamp.attempt)
		switch progress {
		case .textDelta, .attemptRestarted:
			mailbox.publish(liveText: true)
		case .activity, .proposalPending:
			mailbox.publish()
		}
	}
}
