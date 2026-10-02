import Foundation

final class MailboxLifecycle {
	private let lifetime: Coach.Lifetime
	private var leases: LeaseSlot
	private var completedAway: Set<TurnID> = []

	init(
		host: any ExecutionHost, chat: ChatID, lifetime: Coach.Lifetime,
		language: @escaping @Sendable () async -> LanguageTag
	) {
		self.lifetime = lifetime
		self.leases = LeaseSlot(host: host, chat: chat, language: language)
	}

	var terminating: Bool { lifetime.terminating }
	var finishedAway: Set<TurnID> { completedAway }

	func cancelInFlight(
		cause: InterruptionCause, work: MailboxExecution, records: ChatRecords,
		door: Turnstile, on mailbox: isolated ChatMailbox
	) async {
		let terminating = cause == .appTerminating
		let owned = work.phase.cause == nil
		if !terminating {
			guard owned else { return await work.joinInterruption() }
			guard work.phase.running != nil || work.window != nil || !work.isEmpty || door.held
			else { return }
		}
		if owned { work.beginInterruption(cause) }
		mailbox.publish()
		work.phase.running?.task.cancel()
		let settle = {
			await work.cancelCoalescing()
			if terminating { _ = work.closeWindow() }
			await work.phase.running?.task.value
			if !terminating {
				let unstarted = work.dropWaiting() + [work.closeWindow()].compactMap { $0 }
				await records.stopBeforeStart(unstarted)
			}
			self.leases.end { $0.interrupt() }
			if owned { work.endInterruption() }
		}
		await door.pass(settle)
		mailbox.publish()
		if !terminating { work.drainIfIdle(on: mailbox) }
	}

	func recover(
		_ plan: RecoveryPlan, records: ChatRecords, work: MailboxExecution,
		on mailbox: isolated ChatMailbox
	) async {
		await records.recover(plan.interrupt)
		for job in plan.drain {
			work.add(job, on: mailbox)
		}
		mailbox.publish()
	}

	func hold(_ initiator: LeaseInitiator, on mailbox: isolated ChatMailbox) -> DrainLease? {
		guard !lifetime.terminating else { return nil }
		return leases.hold(initiator) { [weak mailbox] generation, cause in
			await mailbox?.expire(cause, lease: generation)
		}
	}

	func expire(
		_ cause: ExpiryCause, lease generation: Int, on mailbox: isolated ChatMailbox
	) async {
		guard leases.holds(generation) else { return }
		await mailbox.cancelInFlight(cause: InterruptionCause(cause))
	}

	func finishDrain(window: OpenWindow?, cause: InterruptionCause?) {
		if window == nil, cause == nil, !lifetime.terminating {
			leases.end { $0.finish() }
		}
	}

	func finish(_ turn: TurnID, reply: ReplyText?, under lease: DrainLease) {
		if reply != nil, !lifetime.foreground {
			completedAway.insert(turn)
		}
		lease.settle(turn, reply: reply)
	}
}
