import Foundation
import Synchronization

extension WorkoutReviewDesk {
	func approving(_ token: ReviewControlToken) async -> ReviewOutcome {
		let head: RecordHead
		let review: WorkoutReview
		switch await admit(token, allowing: { $0 == .approveOrCancel }) {
		case .refused(let outcome): return outcome
		case .admitted(let admittedHead, let admitted):
			head = admittedHead
			review = admitted
		}
		let claimed: WorkoutReview
		do throws(TransitionRefusal) {
			claimed = try review.claimed(
				Claim(id: ClaimID(ulid: await ledger.nextULID()), action: .approve))
		} catch {
			return .wrongAction
		}
		let stamp = stamp(for: claimed, attempt: await ledger.nextULID())
		let run = DriveLease()
		let lease = await host.beginLease(
			LeaseRequest(chat: claimed.chat, initiatedBy: .athlete)
		) { cause in
			await run.expire(cause)
		}
		let task = Task { await self.claim(claimed, after: head, stamp: stamp) }
		run.start(task)
		let outcome = await task.value
		await lease.end(run.ending(after: outcome))
		return outcome
	}

	func canceling(_ token: ReviewControlToken) async -> ReviewOutcome {
		let head: RecordHead
		let review: WorkoutReview
		switch await admit(token, allowing: { _ in true }) {
		case .refused(let outcome): return outcome
		case .admitted(let admittedHead, let admitted):
			head = admittedHead
			review = admitted
		}
		let canceled: WorkoutReview
		do throws(TransitionRefusal) {
			canceled = try review.canceled()
		} catch {
			return .wrongAction
		}
		let stamp = stamp(for: canceled, attempt: await ledger.nextULID())
		let saved: RecordHead
		do throws(TransitionFailure) {
			saved = .record(
				try await ledger.commit(review: canceled, stamp: stamp, after: head).ulid)
		} catch {
			return ending(error, in: canceled.chat)
		}
		deliveries[canceled.chat] = nil
		moved(canceled.chat)
		return await effects.pass {
			await drive(canceled, at: saved, from: .claimed, stamp: stamp)
		}
	}

	func checkingAgain(_ token: ReviewControlToken) async -> ReviewOutcome {
		switch await admit(token, allowing: { $0 == .checkAgainOrCancel }) {
		case .refused(let outcome):
			return outcome
		case .admitted(let head, let review):
			return await drive(
				review, at: head, from: .resume,
				stamp: stamp(for: review, attempt: await ledger.nextULID()))
		}
	}

	package func recover() async {
		await effects.pass {
			let chats: Set<ChatID>
			do throws(LedgerFailure) {
				chats = try await ledger.reviewChats()
			} catch {
				diagnostics.record(.recoveryUnavailable(error))
				return
			}
			for chat in chats.sorted(by: { $0.rawValue < $1.rawValue }) {
				await resume(chat)
			}
		}
	}

	private func resume(_ chat: ChatID) async {
		if stalled.contains(chat) { moved(chat) }
		let head: RecordHead
		let review: WorkoutReview
		let published: Bool
		do throws(LedgerFailure) {
			let current = try await ledger.reviewHead(chat: chat)
			guard let saved = current.1 else { return }
			head = current.0
			review = saved
			published = try await isPublished(saved)
		} catch {
			diagnostics.record(.reviewUnavailable(chat, error))
			return
		}
		guard review.nextStep(.resume, summarySaved: published) != .idle else { return }
		_ = await drive(
			review, at: head, from: .resume,
			stamp: stamp(for: review, attempt: await ledger.nextULID()))
	}

	private func admit(
		_ token: ReviewControlToken, allowing allows: (ControlSet) -> Bool
	) async -> Admission {
		let chat = token.ref.chat
		guard let delivery = deliveries[chat], delivery.admits(token) else {
			return .refused(.staleControl(newer: deliveries[chat]?.ref))
		}
		let current: (RecordHead, WorkoutReview?)
		do throws(LedgerFailure) {
			current = try await ledger.reviewHead(chat: chat)
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
			return .refused(.storageUnavailable)
		}
		guard current.0 == .record(delivery.head), let review = current.1 else {
			return .refused(.staleControl(newer: nil))
		}
		guard let controls = review.allowedControls, allows(controls) else {
			return .refused(.wrongAction)
		}
		return .admitted(current.0, review)
	}

	private func claim(_ claimed: WorkoutReview, after head: RecordHead, stamp: OperationStamp)
		async -> ReviewOutcome
	{
		let saved: RecordHead
		do throws(TransitionFailure) {
			saved = .record(
				try await ledger.commit(review: claimed, stamp: stamp, after: head).ulid)
		} catch {
			return ending(error, in: claimed.chat)
		}
		deliveries[claimed.chat] = nil
		moved(claimed.chat)
		return await drive(claimed, at: saved, from: .claimed, stamp: stamp)
	}

	private func drive(
		_ start: WorkoutReview, at saved: RecordHead, from first: DriveStart,
		stamp: OperationStamp
	) async -> ReviewOutcome {
		var review = start
		var head = saved
		var step = first
		var calendar: ConnectedTraining?
		var summarySaved = false
		while true {
			let next: WorkoutReview?
			defer { step = .claimed }
			do throws(TransitionRefusal) {
				switch review.nextStep(step, summarySaved: summarySaved) {
				case .idle:
					return ReviewProjection.outcome(after: review)
				case .publish:
					guard await publish(review, stamp: stamp) else { return stall(review.chat) }
					summarySaved = true
					continue
				case .preflight:
					let checked = try await preflight(review)
					next = checked.review
					calendar = checked.calendar
				case .send(let attempt):
					next = try await send(attempt, of: review, on: calendar)
				case .settle(let attempt):
					next = try review.settled(await settle(attempt, of: review))
				case .restore:
					next = try review.restoredAfterInterruption()
				}
			} catch {
				return .staleControl(newer: nil)
			}
			guard let next else { return ReviewProjection.outcome(after: review) }
			do throws(TransitionFailure) {
				let record = try await ledger.commit(review: next, stamp: stamp, after: head)
				head = .record(record.ulid)
				review = next
				if case .waiting = next.stage {
					deliveries[next.chat] = .fresh(for: next, at: record.ulid)
				}
				moved(next.chat)
			} catch {
				return ending(error, in: next.chat)
			}
		}
	}

	private func preflight(_ review: WorkoutReview) async throws(TransitionRefusal)
		-> (review: WorkoutReview, calendar: ConnectedTraining?)
	{
		let connection: TrainingConnection
		do throws(AccessUnavailable) {
			connection = try await training(true)
		} catch {
			return (try review.pausedUnchecked(), nil)
		}
		let calendar: ConnectedTraining? =
			if case .connected(let connected) = connection { connected } else { nil }
		switch await Preflight.run(review, connection: connection, clock: clock) {
		case .clear(_, let seen):
			return (try review.sending(at: clock.now, seen: seen), calendar)
		case .changed(let targets, let kept, let differences):
			return (try review.refreshed(targets, kept: kept, differences: differences), calendar)
		case .blocked(let block):
			return (try review.blocked(block), calendar)
		case .unchecked:
			return (try review.pausedUnchecked(), calendar)
		}
	}

	private func send(
		_ attempt: SendAttempt, of review: WorkoutReview, on calendar: ConnectedTraining?
	) async throws(TransitionRefusal) -> WorkoutReview? {
		let answer: SendAnswer
		if let calendar, !Task.isCancelled {
			answer = await CalendarWriter.send(attempt, on: calendar.client, now: clock.now)
		} else {
			answer = .lost(.canceled)
		}
		switch try review.answered(answer, at: clock.now) {
		case .next(let next):
			return next
		case .readFirst(let unanswered):
			return try review.settled(await read(unanswered, on: calendar))
		}
	}

	private func settle(_ attempt: SendAttempt, of review: WorkoutReview) async -> SettleRead {
		let connection: TrainingConnection
		do throws(AccessUnavailable) {
			connection = try await training(true)
		} catch {
			return .readFailed
		}
		guard case .connected(let connected) = connection,
			review.account.authority(under: connected.account).permitsWrites
		else { return .readFailed }
		return await read(attempt, on: connected)
	}

	private func read(_ attempt: SendAttempt, on calendar: ConnectedTraining?) async -> SettleRead {
		guard let calendar, !Task.isCancelled else { return .readFailed }
		return await CalendarWriter.settle(attempt, on: calendar.client)
	}

	private func ending(_ failure: TransitionFailure, in chat: ChatID) -> ReviewOutcome {
		switch failure {
		case .headMoved:
			return .staleControl(newer: nil)
		case .storage(let storage):
			diagnostics.record(.reviewOutcomeUnsaved(storage))
			return stall(chat)
		}
	}

	private func stamp(for review: WorkoutReview, attempt: ULID) -> OperationStamp {
		OperationStamp(
			operation: .workoutReview(review.id, review.revision),
			attempt: AttemptID(ulid: attempt),
			binding: ActionBinding(
				account: review.account, zone: AthleteCalendar(clock: clock).deviceZone))
	}
}

private enum Admission {
	case admitted(RecordHead, WorkoutReview)
	case refused(ReviewOutcome)
}

private final class DriveLease: Sendable {
	private struct State {
		var task: Task<ReviewOutcome, Never>?
		var expiry: ExpiryCause?
	}

	private let state = Mutex(State())

	func start(_ task: Task<ReviewOutcome, Never>) {
		let expired = state.withLock { current in
			current.task = task
			return current.expiry != nil
		}
		if expired { task.cancel() }
	}

	func expire(_ cause: ExpiryCause) async {
		let task = state.withLock { current in
			current.expiry = cause
			return current.task
		}
		task?.cancel()
		_ = await task?.value
	}

	func ending(after outcome: ReviewOutcome) -> LeaseEnding {
		if let expiry = state.withLock({ $0.expiry }) {
			return .interrupted(InterruptionCause(expiry))
		}
		return outcome == .storageUnavailable ? .failed : .finished
	}
}
