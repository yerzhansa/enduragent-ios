import Foundation

package struct SendAttempt: Equatable, Sendable {
	package let change: ReviewChange
	package let claim: ClaimID
	package let sentAt: Date

	fileprivate init(change: ReviewChange, claim: ClaimID, sentAt: Date) {
		self.change = change
		self.claim = claim
		self.sentAt = sentAt
	}
}

package enum Waiting: Equatable, Sendable {
	case approval(ApprovalReason)
	case tryAgain(TryAgainReason)
	case unconfirmed(SendAttempt)
	case blocked(ReviewBlock)
}

package struct Run: Equatable, Sendable {
	package let claim: Claim
	package let sending: SendAttempt?
}

package struct Cancellation: Equatable, Sendable {
	package let givenUp: [ReviewChange]
	package let unconfirmed: SendAttempt?
}

package enum Stage: Equatable, Sendable {
	case waiting(Waiting)
	case running(Run)
	case completed
	case canceled(Cancellation)

	package var changes: [ReviewChange] {
		switch self {
		case .waiting(.unconfirmed(let attempt)): [attempt.change]
		case .running(let run): run.sending.map { [$0.change] } ?? []
		case .canceled(let cancellation):
			cancellation.givenUp + (cancellation.unconfirmed.map { [$0.change] } ?? [])
		case .waiting, .completed: []
		}
	}
}

package struct WorkoutReview: Equatable, Sendable {
	package let id: WorkoutReviewID
	package let revision: ReviewRevision
	package let chat: ChatID
	package let account: TrainingAccount
	package let origin: DraftKey
	package let work: ReviewWork
	package let kept: [KeptWorkout]
	package let stage: Stage

	fileprivate init(
		id: WorkoutReviewID, revision: ReviewRevision, chat: ChatID, account: TrainingAccount,
		origin: DraftKey, work: ReviewWork, kept: [KeptWorkout], stage: Stage
	) {
		self.id = id
		self.revision = revision
		self.chat = chat
		self.account = account
		self.origin = origin
		self.work = work
		self.kept = kept
		self.stage = stage
	}
}

package enum AnswerStep: Equatable, Sendable {
	case next(WorkoutReview)
	case readFirst(SendAttempt)
}

package enum DriveStart: Equatable, Sendable {
	case claimed
	case resume
}

package enum NextStep: Equatable, Sendable {
	case idle
	case preflight
	case send(SendAttempt)
	case settle(SendAttempt)
	case restore
	case publish
}

extension WorkoutReview {
	static func committing(
		_ draft: ReviewDraft, _ work: [ReviewChange], kept: [KeptWorkout],
		over base: WorkoutReview?, id fresh: WorkoutReviewID
	) -> WorkoutReview {
		WorkoutReview(
			id: base?.id ?? fresh, revision: base?.revision.next ?? ReviewRevision(rawValue: 1),
			chat: draft.chat, account: draft.binding.account, origin: draft.key,
			work: ReviewWork(finished: base?.work.finished ?? [], remaining: work), kept: kept,
			stage: .waiting(.approval(base == nil ? .prepared : .revised)))
	}

	static func upgraded(_ legacy: LegacyUnknownWrite, change: ChangeID, claim: ClaimID)
		-> WorkoutReview
	{
		let sent = ReviewChange(id: change, position: 0, action: legacy.change)
		return WorkoutReview(
			id: legacy.review, revision: ReviewRevision(rawValue: 1), chat: legacy.chat,
			account: legacy.account, origin: legacy.origin,
			work: ReviewWork(finished: [], remaining: []), kept: [],
			stage: .waiting(
				.unconfirmed(SendAttempt(change: sent, claim: claim, sentAt: legacy.sentAt))))
	}

	package func claimed(_ claim: Claim) throws(TransitionRefusal) -> WorkoutReview {
		guard case .waiting(let waiting) = stage else { throw .wrongStage }
		switch (waiting, claim.action) {
		case (.approval, .approve), (.tryAgain, .tryAgain):
			return with(work, .running(Run(claim: claim, sending: nil)))
		case (.approval, .tryAgain), (.tryAgain, .approve):
			throw .wrongAction
		case (.unconfirmed, _), (.blocked, _):
			throw .wrongStage
		}
	}

	package func refreshed(
		_ targets: [ChangeID: WorkoutSnapshot], kept: [KeptWorkout],
		differences: [TargetDifference]
	) throws(TransitionRefusal) -> WorkoutReview {
		_ = try checkingRun()
		return WorkoutReview(
			id: id, revision: revision.next, chat: chat, account: account, origin: origin,
			work: ReviewWork(
				finished: work.finished,
				remaining: work.remaining.map { $0.reviewing(targets[$0.id]) }),
			kept: kept, stage: .waiting(.approval(.refreshed(differences))))
	}

	package func blocked(_ block: ReviewBlock) throws(TransitionRefusal) -> WorkoutReview {
		_ = try checkingRun()
		return with(work, .waiting(.blocked(block)))
	}

	package func pausedUnchecked() throws(TransitionRefusal) -> WorkoutReview {
		_ = try checkingRun()
		let waiting: Waiting =
			work.finished.isEmpty ? .approval(.couldNotCheck) : .tryAgain(.couldNotCheck)
		return with(work, .waiting(waiting))
	}

	package func sending(at now: Date, seen: [ChangeID: EventID]) throws(TransitionRefusal)
		-> WorkoutReview
	{
		sending(try checkingRun().claim, finished: work.finished, at: now, seen: seen)
	}

	package func answered(_ answer: SendAnswer, at now: Date) throws(TransitionRefusal)
		-> AnswerStep
	{
		guard case .running(let run) = stage, let attempt = run.sending else {
			throw .wrongStage
		}
		switch answer {
		case .saved(let receipt):
			return .next(
				sending(
					run.claim, finished: finishing(attempt.change, .saved(receipt)), at: now,
					seen: [:]))
		case .gone:
			guard case .delete = attempt.change.action else { return .readFirst(attempt) }
			return .next(
				sending(
					run.claim, finished: finishing(attempt.change, .noLongerOnCalendar), at: now,
					seen: [:]))
		case .refused(let status):
			return .next(
				with(
					ReviewWork(
						finished: work.finished, remaining: [attempt.change] + work.remaining),
					.waiting(.tryAgain(.refused(attempt.change.id, status)))))
		case .lost:
			return .readFirst(attempt)
		}
	}

	package func settled(_ read: SettleRead) throws(TransitionRefusal) -> WorkoutReview? {
		let attempt: SendAttempt
		let alreadyUnconfirmed: Bool
		switch stage {
		case .running(let run):
			guard let sending = run.sending else { throw .wrongStage }
			attempt = sending
			alreadyUnconfirmed = false
		case .waiting(.unconfirmed(let unconfirmed)):
			attempt = unconfirmed
			alreadyUnconfirmed = true
		case .waiting, .completed, .canceled:
			throw .wrongStage
		}
		switch read {
		case .seen(let event):
			return settling(attempt.change, as: .seenOnCalendar(event))
		case .gone:
			return settling(attempt.change, as: .noLongerOnCalendar)
		case .notSaved:
			return returning(attempt.change)
		case .readFailed:
			return alreadyUnconfirmed ? nil : with(work, .waiting(.unconfirmed(attempt)))
		}
	}

	package func restoredAfterInterruption() throws(TransitionRefusal) -> WorkoutReview {
		_ = try checkingRun()
		let waiting: Waiting =
			work.finished.isEmpty
			? .approval(.interruptedBeforeWriting) : .tryAgain(.interrupted)
		return with(work, .waiting(waiting))
	}

	package func canceled() throws(TransitionRefusal) -> WorkoutReview {
		guard case .waiting(let waiting) = stage else { throw .wrongStage }
		let unconfirmed: SendAttempt? =
			if case .unconfirmed(let attempt) = waiting { attempt } else { nil }
		return with(
			ReviewWork(finished: work.finished, remaining: []),
			.canceled(Cancellation(givenUp: work.remaining, unconfirmed: unconfirmed)))
	}

	package func nextStep(_ start: DriveStart, summarySaved: Bool) -> NextStep {
		switch (stage, start) {
		case (.running(let run), .claimed): run.sending.map(NextStep.send) ?? .preflight
		case (.running(let run), .resume): run.sending.map(NextStep.settle) ?? .restore
		case (.waiting(.unconfirmed(let attempt)), .resume): .settle(attempt)
		case (.waiting, _): .idle
		case (.completed, _), (.canceled, _): summarySaved ? .idle : .publish
		}
	}

	package var allowedControls: ControlSet? {
		guard case .waiting(let waiting) = stage else { return nil }
		return switch waiting {
		case .approval: .approveOrCancel
		case .tryAgain: .tryAgainOrCancel
		case .unconfirmed: .checkAgainOrCancel
		case .blocked: .cancelOnly
		}
	}

	private func checkingRun() throws(TransitionRefusal) -> Run {
		guard case .running(let run) = stage, run.sending == nil else { throw .wrongStage }
		return run
	}

	private func with(_ work: ReviewWork, _ stage: Stage) -> WorkoutReview {
		WorkoutReview(
			id: id, revision: revision, chat: chat, account: account, origin: origin, work: work,
			kept: kept, stage: stage)
	}

	private func finishing(_ change: ReviewChange, _ result: ChangeResult) -> [FinishedChange] {
		work.finished + [FinishedChange(change: change, result: result)]
	}

	private func sending(
		_ claim: Claim, finished: [FinishedChange], at now: Date, seen: [ChangeID: EventID]
	) -> WorkoutReview {
		var finished = finished
		var unsent: [ReviewChange] = []
		for change in work.remaining {
			if case .add = change.action, let event = seen[change.id] {
				finished.append(FinishedChange(change: change, result: .seenOnCalendar(event)))
			} else {
				unsent.append(change)
			}
		}
		guard let next = unsent.first else {
			return with(ReviewWork(finished: finished, remaining: []), .completed)
		}
		let attempt = SendAttempt(change: next, claim: claim.id, sentAt: now)
		return with(
			ReviewWork(finished: finished, remaining: Array(unsent.dropFirst())),
			.running(Run(claim: claim, sending: attempt)))
	}

	private func settling(_ change: ReviewChange, as result: ChangeResult) -> WorkoutReview {
		let settled = ReviewWork(
			finished: finishing(change, result), remaining: work.remaining)
		return with(settled, work.remaining.isEmpty ? .completed : .waiting(.tryAgain(.settled)))
	}

	private func returning(_ change: ReviewChange) -> WorkoutReview {
		let waiting: Waiting =
			if change.isUpgradedWithoutSnapshot {
				.blocked(.reviewedBeforeUpgrade)
			} else if work.finished.isEmpty {
				.approval(.interruptedBeforeWriting)
			} else {
				.tryAgain(.notSaved(change.id))
			}
		return with(
			ReviewWork(finished: work.finished, remaining: [change] + work.remaining),
			.waiting(waiting))
	}
}

package enum WorkoutReviewPayload {
	package static func encode(_ review: WorkoutReview) throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return try encoder.encode(ReviewDocument(review))
	}

	package static func decode(_ data: Data) throws -> WorkoutReview {
		let review = try JSONDecoder().decode(ReviewDocument.self, from: data).review()
		guard review.isWellFormed else {
			throw RecordDecodeFailure(reason: "workoutReview")
		}
		return review
	}
}

extension WorkoutReview {
	fileprivate var isWellFormed: Bool {
		let changes = work.finished.map(\.change) + work.remaining + stage.changes
		guard !changes.isEmpty, revision.rawValue >= 1,
			Set(changes.map(\.id)).count == changes.count,
			Set(changes.map(\.position)).count == changes.count
		else { return false }
		switch stage {
		case .completed, .canceled:
			return work.remaining.isEmpty
		case .running(let run):
			guard let attempt = run.sending else { return !work.remaining.isEmpty }
			return attempt.claim == run.claim.id
		case .waiting(.unconfirmed):
			return true
		case .waiting(.approval), .waiting(.tryAgain), .waiting(.blocked):
			return !work.remaining.isEmpty
		}
	}
}

extension ReviewDocument {
	fileprivate func review() throws -> WorkoutReview {
		WorkoutReview(
			id: WorkoutReviewID(ulid: try decodeULID(id)),
			revision: ReviewRevision(rawValue: revision),
			chat: try decodeChatID(chat),
			account: try decodeAccount(account),
			origin: DraftKey(
				turn: TurnID(ulid: try decodeULID(turn)),
				attempt: AttemptID(ulid: try decodeULID(attempt))),
			work: ReviewWork(
				finished: try finished.map { try $0.finished() },
				remaining: try remaining.map { try $0.change() }),
			kept: try kept.map { try $0.kept() },
			stage: try stage.stage())
	}
}

extension StageDocument {
	fileprivate func stage() throws -> Stage {
		switch self {
		case .waiting(let waiting): .waiting(try waiting.waiting())
		case .running(let claim, let sending):
			.running(Run(claim: try claim.claim(), sending: try sending.map { try $0.attempt() }))
		case .completed: .completed
		case .canceled(let givenUp, let unconfirmed):
			.canceled(
				Cancellation(
					givenUp: try givenUp.map { try $0.change() },
					unconfirmed: try unconfirmed.map { try $0.attempt() }))
		}
	}
}

extension WaitingDocument {
	fileprivate func waiting() throws -> Waiting {
		switch self {
		case .approval(let reason): .approval(try reason.reason())
		case .tryAgain(let reason): .tryAgain(try reason.reason())
		case .unconfirmed(let attempt): .unconfirmed(try attempt.attempt())
		case .blocked(let block): .blocked(block.block)
		}
	}
}

extension SendAttemptDocument {
	fileprivate func attempt() throws -> SendAttempt {
		SendAttempt(
			change: try change.change(), claim: ClaimID(ulid: try decodeULID(claim)),
			sentAt: Date(timeIntervalSince1970: sentAt))
	}
}
