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

struct UpgradePlan: Equatable, Sendable {
	let closed: [LegacyClosure]
	let unconfirmed: [LegacyUnknownWrite]
	let unreadable: [ULID]
}

enum ReviewUpgrade {
	static func plan(
		proposals: [LegacyProposal], writes: [LegacyWrite], reviewed: Set<WorkoutReviewID>,
		device: DeviceID
	) -> UpgradePlan {
		let sent = Set(writes.filter(\.body.evidence.dispatched).map(\.body.review))
		let closed = proposals.compactMap { proposal -> LegacyClosure? in
			guard !reviewed.contains(proposal.review), !sent.contains(proposal.review) else {
				return nil
			}
			return LegacyClosure(
				summary: ReviewOutcomeBody(
					chatId: proposal.body.chatId, review: proposal.review,
					revision: ReviewRevision(rawValue: 1), after: proposal.origin?.turn,
					ending: .closedAtUpgrade, lines: []),
				account: proposal.record.account)
		}
		var unconfirmed: [LegacyUnknownWrite] = []
		var unreadable: [ULID] = []
		for write in writes where !reviewed.contains(write.body.review) {
			guard write.record.deviceId == device, write.cancellation == nil,
				case .unknown = write.body.evidence, let identity = write.body.writeID,
				let proposal = write.proposal, let origin = proposal.origin
			else { continue }
			do throws(UnreadableWrite) {
				unconfirmed.append(
					LegacyUnknownWrite(
						review: write.body.review, chat: write.body.chatId,
						account: write.record.account, origin: origin,
						change: try change(
							proposal.body.change, at: write.body.target, as: identity),
						sentAt: write.record.hlc.wallTime))
			} catch {
				unreadable.append(write.record.ulid)
			}
		}
		return UpgradePlan(closed: closed, unconfirmed: unconfirmed, unreadable: unreadable)
	}

	private static func change(
		_ change: LegacyCalendarChange, at target: CalendarWriteTarget?,
		as identity: CalendarWriteID
	) throws(UnreadableWrite) -> ChangeAction {
		switch (change, target) {
		case (.add(let payload, let ride), .create?):
			return .add(
				AddedWorkout(payload: try authored(payload, ride: ride), identity: identity))
		case (.edit(let id, let patch), .update(let event, let date)?) where event == id.rawValue:
			guard let day = CivilDate(rawValue: date) else { throw .target }
			return .edit(EditedWorkout(target: .upgradedWithoutSnapshot(id, day), patch: patch))
		case (.delete(let id), .delete(let event, let date)?) where event == id.rawValue:
			guard let day = CivilDate(rawValue: date) else { throw .target }
			return .delete(DeletedWorkout(target: .upgradedWithoutSnapshot(id, day)))
		default:
			throw .target
		}
	}

	private static func authored(_ payload: CalendarPayload, ride: IntervalsWorkoutInput?)
		throws(UnreadableWrite) -> CalendarPayload
	{
		guard let ride else { return payload }
		let steps: AuthoredSteps
		do throws(InvalidWorkout) {
			steps = try AuthoredSteps.ride(ride.toolInput)
		} catch {
			throw .steps(error)
		}
		return CalendarPayload(
			date: payload.date, type: payload.type, name: payload.name,
			description: payload.description, movingTime: payload.movingTime,
			trainingLoad: payload.trainingLoad, authoredSteps: steps)
	}
}

private enum UnreadableWrite: Error {
	case target
	case steps(InvalidWorkout)
}

extension IntervalsWorkoutInput {
	fileprivate var toolInput: JSONValue {
		.object(["name": .string(name), "steps": .array(steps.map(\.toolInput))])
	}
}

extension WorkoutStep {
	fileprivate var toolInput: JSONValue {
		switch self {
		case .simple(let step):
			step.toolInput
		case .set(let set):
			.object([
				"type": .string(StepType.set.rawValue),
				"repeat": .number(Double(set.repeatCount)),
				"interval": set.interval.toolInput,
				"recovery": set.recovery.toolInput,
			])
		}
	}
}

extension SimpleStep {
	fileprivate var toolInput: JSONValue {
		var fields: [String: JSONValue] = [
			"type": .string(type.rawValue),
			"duration": .object([
				"value": .number(duration.value), "unit": .string(duration.unit.rawValue),
			]),
		]
		if let power {
			var target: [String: JSONValue] = ["kind": .string(power.kind.rawValue)]
			target["value"] = power.value.map(JSONValue.number)
			target["low"] = power.low.map(JSONValue.number)
			target["high"] = power.high.map(JSONValue.number)
			fields["power"] = .object(target)
		}
		if let cadence {
			var target: [String: JSONValue] = [:]
			target["value"] = cadence.value.map { .number(Double($0)) }
			target["low"] = cadence.low.map { .number(Double($0)) }
			target["high"] = cadence.high.map { .number(Double($0)) }
			fields["cadence"] = .object(target)
		}
		if let label {
			fields["label"] = .string(label)
		}
		return .object(fields)
	}
}

extension WorkoutReviewDesk {
	func upgrade() async {
		do throws(LedgerFailure) {
			let legacy = try await legacyReviews()
			let reviewed = try await summaryIDs().union(try await headIDs())
			let plan = ReviewUpgrade.plan(
				proposals: legacy.proposals, writes: legacy.writes, reviewed: reviewed,
				device: ledger.deviceId)
			for ulid in plan.unreadable {
				diagnostics.record(
					.skippedRecord(
						.malformed(kind: LegacyKind.reviewWrite.rawValue, ulid: ulid.rawValue)))
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
		try await commitOnce(
			summary,
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
		if try await chainIDs(in: write.chat).contains(write.review) { return }
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
		proposals: [LegacyProposal], writes: [LegacyWrite]
	) {
		let local = try await ledger.read(RecordQuery(scope: LegacyReviewRecords.localScope))
			.records
		let synced = try await ledger.read(RecordQuery(scope: LegacyReviewRecords.syncedScope))
			.records
		var proposals: [LegacyProposal] = []
		var writes: [LegacyWrite] = []
		let chats = Set((local + synced).compactMap(\.chatId))
		for chat in chats.sorted(by: { $0.rawValue < $1.rawValue }) {
			if let live = LegacyReviewRecords.liveProposal(in: local, chat: chat, now: clock.now) {
				proposals.append(live)
			}
			writes += LegacyReviewRecords.writes(in: chat, synced: synced, local: local)
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

	private func chainIDs(in chat: ChatID) async throws(LedgerFailure) -> Set<WorkoutReviewID> {
		Set(
			try await ledger.read(
				RecordQuery(scope: .deviceLocal([.workoutReview]), chatId: chat)
			).records
				.compactMap { record in
					guard case .deviceLocal(.workoutReview(let body)) = record.body else {
						return nil
					}
					return body.review.id
				})
	}
}
