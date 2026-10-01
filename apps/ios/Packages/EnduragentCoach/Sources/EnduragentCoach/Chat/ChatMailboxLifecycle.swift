import Foundation

extension ChatMailbox {
	package func cancelInFlight(cause: InterruptionCause) async {
		let terminating = cause == .appTerminating
		let owned = work.phase.cause == nil
		if !terminating {
			guard owned else { return await work.joinInterruption() }
			guard work.phase.running != nil || work.window != nil || !work.isEmpty || door.held
			else { return }
		}
		if owned { work.beginInterruption(cause) }
		publish()
		work.phase.running?.task.cancel()
		let settle = {
			await self.work.phase.running?.task.value
			if !terminating {
				let unstarted =
					self.work.dropWaiting() + [self.work.closeWindow()].compactMap { $0 }
				for turn in unstarted {
					let stamp = await self.stamp(for: turn)
					let stopped = TurnLifecycle.stopBeforeStart(
						stamp.attempt, on: self.conversation.turn(turn), chat: self.chatId)
					guard case .success(let settled) = stopped else { continue }
					await self.records.settle(settled, stamp: stamp)
				}
			}
			self.leases.end { $0.interrupt() }
			if owned { self.work.endInterruption() }
		}
		if terminating {
			await settle()
		} else {
			await door.pass(settle)
		}
		publish()
		if !terminating { drainIfIdle() }
	}

	package func enteredBackground() async {
		await door.pass { closeWindow() }
	}

	package func recover(_ plan: RecoveryPlan) async {
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

	func holdLease(_ initiator: LeaseInitiator) -> DrainLease? {
		guard !lifetime.terminating else { return nil }
		return leases.hold(initiator) { [weak self] generation, cause in
			await self?.expire(cause, lease: generation)
		}
	}

	private func expire(_ cause: ExpiryCause, lease generation: Int) async {
		guard leases.holds(generation) else { return }
		await cancelInFlight(cause: InterruptionCause(cause))
	}
}
