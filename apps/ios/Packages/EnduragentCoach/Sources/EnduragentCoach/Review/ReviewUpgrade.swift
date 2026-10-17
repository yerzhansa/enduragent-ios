import Foundation

struct LegacyUnknownWrite: Equatable, Sendable {
	let review: WorkoutReviewID
	let chat: ChatID
	let account: TrainingAccount
	let origin: DraftKey
	let change: ChangeAction
	let sentAt: Date
}

struct LegacyClosure: Equatable, Sendable {
	let summary: ReviewOutcomeBody
	let account: TrainingAccount
}

struct LegacyWriteFault: Equatable, Sendable {
	let attempt: AttemptID
	let tool: ToolName
	let fault: ToolFault
}

struct UpgradePlan: Equatable, Sendable {
	let closed: [LegacyClosure]
	let unconfirmed: [LegacyUnknownWrite]
	let unreadable: [LegacyWriteFault]

	var writesNothing: Bool { closed.isEmpty && unconfirmed.isEmpty }
}

enum ReviewUpgrade {
	static func plan(
		proposals: [LiveProposal], writes: [CalendarWriteIntent], reviewed: Set<WorkoutReviewID>,
		device: DeviceID
	) -> UpgradePlan {
		let sent = Set(writes.filter(\.body.evidence.dispatched).map(\.body.review))
		let closed = proposals.compactMap { proposal -> LegacyClosure? in
			let review = WorkoutReviewID(ulid: proposal.ulid)
			guard !reviewed.contains(review), !sent.contains(review) else { return nil }
			return LegacyClosure(
				summary: ReviewOutcomeBody(
					chatId: proposal.body.chatId, review: review,
					revision: ReviewRevision(rawValue: 1), after: proposal.origin?.turn,
					ending: .closedAtUpgrade, lines: []),
				account: proposal.account)
		}
		var unconfirmed: [LegacyUnknownWrite] = []
		var unreadable: [LegacyWriteFault] = []
		for write in writes where !reviewed.contains(write.body.review) {
			guard write.record.deviceId == device, write.cancellation == nil,
				case .unknown = write.body.evidence, let identity = write.body.writeID,
				let proposal = write.proposal, let origin = proposal.origin
			else { continue }
			do {
				unconfirmed.append(
					LegacyUnknownWrite(
						review: write.body.review, chat: write.body.chatId,
						account: write.record.account, origin: origin,
						change: try change(
							proposal.body.toolInput, at: write.body.target, as: identity),
						sentAt: write.record.hlc.wallTime))
			} catch {
				unreadable.append(
					LegacyWriteFault(
						attempt: origin.attempt, tool: proposal.body.tool.toolName,
						fault: ToolFault(error)))
			}
		}
		return UpgradePlan(closed: closed, unconfirmed: unconfirmed, unreadable: unreadable)
	}

	private static func change(
		_ input: GatedToolInput, at target: CalendarWriteTarget?, as identity: CalendarWriteID
	) throws -> ChangeAction {
		switch (input, target) {
		case (.createWorkout, .create?), (.createStrengthWorkout, .create?):
			return .add(
				AddedWorkout(
					payload: try CalendarWriteOperation.creation(input), identity: identity))
		case (.updateWorkout(let update), .update(let event, let date)?)
		where event == update.eventId.rawValue:
			return .edit(
				EditedWorkout(
					target: .upgradedWithoutSnapshot(update.eventId, try decodeCivilDate(date)),
					patch: CalendarWriteOperation.patch(update)))
		case (.deleteWorkout(let id), .delete(let event, let date)?) where event == id.rawValue:
			return .delete(
				DeletedWorkout(target: .upgradedWithoutSnapshot(id, try decodeCivilDate(date))))
		default:
			throw RecordDecodeFailure(reason: "reviewWrite target")
		}
	}
}

extension LiveProposal {
	fileprivate var origin: DraftKey? {
		guard case .operation(.turn(let turn), let attempt) = cause else { return nil }
		return DraftKey(turn: turn, attempt: attempt)
	}
}

extension WorkoutReviewDesk {
	func upgrade() async {
		do throws(LedgerFailure) {
			let legacy = try await legacyReviews()
			var reviewed = try await summaryIDs().union(try await headIDs())
			var plan = ReviewUpgrade.plan(
				proposals: legacy.proposals, writes: legacy.writes, reviewed: reviewed,
				device: ledger.deviceId)
			if !plan.writesNothing {
				reviewed.formUnion(try await chainIDs())
				plan = ReviewUpgrade.plan(
					proposals: legacy.proposals, writes: legacy.writes, reviewed: reviewed,
					device: ledger.deviceId)
			}
			for unreadable in plan.unreadable {
				diagnostics.record(
					.toolFailed(unreadable.attempt, unreadable.tool, failure: unreadable.fault))
			}
			for closure in plan.closed {
				try await close(closure)
			}
			for write in plan.unconfirmed {
				try await reopen(write)
			}
		} catch {
			diagnostics.record(.recoveryUnavailable(error))
		}
	}

	private func close(_ closure: LegacyClosure) async throws(LedgerFailure) {
		let summary = closure.summary
		_ = try await ledger.commit(
			synced: [.reviewOutcome(summary)],
			stamp: OperationStamp(
				operation: .workoutReview(summary.review, summary.revision),
				attempt: AttemptID(ulid: await ledger.nextULID()),
				binding: ActionBinding(
					account: closure.account, zone: AthleteCalendar(clock: clock).deviceZone)))
		moved(summary.chatId)
	}

	private func reopen(_ write: LegacyUnknownWrite) async throws(LedgerFailure) {
		let (head, current) = try await ledger.reviewHead(chat: write.chat)
		if let current, !(try await isPublished(current)) { return }
		let review = WorkoutReview.upgraded(
			write, change: ChangeID(ulid: await ledger.nextULID()),
			claim: ClaimID(ulid: await ledger.nextULID()))
		do throws(TransitionFailure) {
			_ = try await ledger.commit(
				review: review, stamp: stamp(for: review, attempt: await ledger.nextULID()),
				after: head)
		} catch {
			switch error {
			case .headMoved: return
			case .storage(let failure): throw failure
			}
		}
		moved(write.chat)
	}

	private func legacyReviews() async throws(LedgerFailure) -> (
		proposals: [LiveProposal], writes: [CalendarWriteIntent]
	) {
		let local = try await ledger.read(
			RecordQuery(scope: .deviceLocal([.pendingProposal, .proposalCleared]))
		).records
		let synced = try await ledger.read(
			RecordQuery(scope: .synced([.reviewWrite, .reviewCancelledUnknown]))
		).records
		var proposals: [LiveProposal] = []
		var writes: [CalendarWriteIntent] = []
		let chats = Set((local + synced).compactMap(\.chatId))
		for chat in chats.sorted(by: { $0.rawValue < $1.rawValue }) {
			if let live = UnionMerge.pendingProposalRecord(local, chatId: chat, now: clock.now) {
				proposals.append(live)
			}
			writes += try await ledger.calendarWrites(chat, synced: synced)
		}
		return (proposals, writes)
	}

	private func summaryIDs() async throws(LedgerFailure) -> Set<WorkoutReviewID> {
		Set(
			try await ledger.read(RecordQuery(scope: .synced([.reviewOutcome]))).records
				.compactMap { record in
					guard case .synced(.reviewOutcome(let body)) = record.body else { return nil }
					return body.review
				})
	}

	private func headIDs() async throws(LedgerFailure) -> Set<WorkoutReviewID> {
		var heads: Set<WorkoutReviewID> = []
		for chat in try await ledger.reviewChats() {
			if let head = try await ledger.reviewHead(chat: chat).1 { heads.insert(head.id) }
		}
		return heads
	}

	private func chainIDs() async throws(LedgerFailure) -> Set<WorkoutReviewID> {
		Set(
			try await ledger.read(RecordQuery(scope: .deviceLocal([.workoutReview]))).records
				.compactMap { record in
					guard case .deviceLocal(.workoutReview(let body)) = record.body else {
						return nil
					}
					return body.review.id
				})
	}
}
