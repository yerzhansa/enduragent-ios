import Foundation

package enum ProposedChange: Equatable, Sendable {
	case add(CalendarPayload)
	case edit(EventID, WorkoutPatch)
	case delete(EventID)
}

package struct ReviewBase: Hashable, Sendable {
	package let review: WorkoutReviewID
	package let revision: ReviewRevision

	init(of review: WorkoutReview) {
		self.review = review.id
		self.revision = review.revision
	}

	init(review: WorkoutReviewID, revision: ReviewRevision) {
		self.review = review
		self.revision = revision
	}
}

package enum PreparationRequest: Equatable, Sendable {
	case complete([ProposedChange])
	case replace(ReviewBase, [ProposedChange])
	case revise(ReviewBase, [ChangeID: ProposedChange])
	case incomplete
}

package struct ProposedTarget: Equatable, Sendable {
	package let reuse: ChangeID?
	package let action: ChangeAction
}

package struct ReviewDraft: Equatable, Sendable {
	package enum Content: Equatable, Sendable {
		case changes(remaining: [ProposedTarget], kept: [KeptWorkout])
		case incomplete
	}

	package let key: DraftKey
	package let chat: ChatID
	package let binding: ActionBinding
	package let base: ReviewBase?
	package let content: Content
}

package enum Preparing: Equatable, Sendable {
	case reading
	case drafted(ReviewDraft, over: RecordHead)
	case refused(PreparationRefusal)
	case abandoned
}

package enum PreparationRefusal: Error, Equatable, Sendable {
	case reviewRunning
	case reviewUnconfirmed
	case reviewWaiting(ReviewBase)
	case staleBase(current: ReviewBase?)
	case unknownItem(ChangeID)
	case twoActionsOnOneWorkout(EventID)
	case ineligible(EventID, Ineligibility)
	case pastDate(CivilDate)
	case targetUnreadable(EventID)
	case keptUnreadable(CivilDate)
	case actionChanged(ChangeID)
	case unchanged(ChangeID)
	case unreadableRequest(ToolInputError)
	case concurrentPreparation
	case storageUnavailable
}

package enum PreparationReply: Equatable, Sendable {
	case drafted(changes: Int, base: ReviewBase?)
	case incomplete
	case refused(PreparationRefusal)
}

package struct PendingItem: Equatable, Sendable {
	package let id: ChangeID
	package let action: ChangeAction
}

package enum PendingReview: Equatable, Sendable {
	case none
	case waiting(ReviewBase, remaining: [PendingItem], finished: Int)
	case busy(ReviewBase)

	init(_ head: WorkoutReview?) {
		guard let head else {
			self = .none
			return
		}
		switch head.stage {
		case .completed, .canceled:
			self = .none
		case .running, .waiting(.unconfirmed):
			self = .busy(ReviewBase(of: head))
		case .waiting:
			self = .waiting(
				ReviewBase(of: head),
				remaining: head.work.remaining.map { PendingItem(id: $0.id, action: $0.action) },
				finished: head.work.finished.count)
		}
	}
}

enum Preparation {
	static func draft(
		_ request: PreparationRequest, key: DraftKey, chat: ChatID, binding: ActionBinding,
		head: WorkoutReview?, reads: any CalendarReads, today: CivilDate
	) async throws(PreparationRefusal) -> ReviewDraft {
		let waiting = try waitingReview(head)
		let planned: (base: ReviewBase?, items: [PlannedChange])
		switch request {
		case .incomplete:
			return ReviewDraft(
				key: key, chat: chat, binding: binding, base: waiting.map(ReviewBase.init(of:)),
				content: .incomplete)
		case .complete(let changes):
			if let waiting { throw .reviewWaiting(ReviewBase(of: waiting)) }
			planned = (nil, changes.map(PlannedChange.proposed))
		case .replace(let base, let changes):
			_ = try matching(base, waiting)
			planned = (base, changes.map(PlannedChange.proposed))
		case .revise(let base, let replacements):
			planned = (base, try revised(try matching(base, waiting), with: replacements))
		}
		try refuseTwoActions(planned.items)
		var remaining: [ProposedTarget] = []
		for item in planned.items {
			remaining.append(try await target(of: item, reads: reads, today: today))
		}
		return ReviewDraft(
			key: key, chat: chat, binding: binding, base: planned.base,
			content: .changes(
				remaining: remaining, kept: try await kept(around: remaining, reads: reads)))
	}

	private static func waitingReview(_ head: WorkoutReview?) throws(PreparationRefusal)
		-> WorkoutReview?
	{
		guard let head else { return nil }
		switch head.stage {
		case .completed, .canceled: return nil
		case .running: throw .reviewRunning
		case .waiting(.unconfirmed): throw .reviewUnconfirmed
		case .waiting: return head
		}
	}

	private static func matching(_ base: ReviewBase, _ waiting: WorkoutReview?)
		throws(PreparationRefusal) -> WorkoutReview
	{
		guard let waiting, ReviewBase(of: waiting) == base else {
			throw .staleBase(current: waiting.map(ReviewBase.init(of:)))
		}
		return waiting
	}

	private static func revised(
		_ waiting: WorkoutReview, with replacements: [ChangeID: ProposedChange]
	) throws(PreparationRefusal) -> [PlannedChange] {
		let pending = Set(waiting.work.remaining.map(\.id))
		if let unknown = replacements.keys.sorted(by: { $0.ulid < $1.ulid }).first(where: {
			!pending.contains($0)
		}) {
			throw .unknownItem(unknown)
		}
		var planned: [PlannedChange] = []
		for change in waiting.work.remaining {
			guard let next = replacements[change.id] else {
				planned.append(.carried(change))
				continue
			}
			planned.append(.replacing(change, with: try revision(of: change, to: next)))
		}
		return planned
	}

	private static func revision(of before: ReviewChange, to next: ProposedChange)
		throws(PreparationRefusal) -> ProposedChange
	{
		switch (before.action, next) {
		case (.add(let add), .add(let payload)) where add.payload.type == payload.type:
			guard add.payload != payload else { throw .unchanged(before.id) }
			return next
		case (.edit(let edit), .edit(let event, let patch)) where edit.target.event == event:
			let merged = edit.patch.revised(by: patch, on: edit.target)
			guard merged != edit.patch else { throw .unchanged(before.id) }
			return .edit(event, merged)
		case (.delete(let delete), .delete(let event)) where delete.target.event == event:
			throw .unchanged(before.id)
		case (.add, _), (.edit, _), (.delete, _):
			throw .actionChanged(before.id)
		}
	}

	private static func refuseTwoActions(_ items: [PlannedChange]) throws(PreparationRefusal) {
		var targeted: Set<EventID> = []
		for event in items.compactMap(\.event) where !targeted.insert(event).inserted {
			throw .twoActionsOnOneWorkout(event)
		}
	}

	private static func target(of item: PlannedChange, reads: any CalendarReads, today: CivilDate)
		async throws(PreparationRefusal) -> ProposedTarget
	{
		let reuse: ChangeID?
		let identity: CalendarWriteID?
		let change: ProposedChange
		switch item {
		case .carried(let carried):
			return ProposedTarget(reuse: carried.id, action: carried.action)
		case .proposed(let proposed):
			(reuse, identity, change) = (nil, nil, proposed)
		case .replacing(let before, let proposed):
			if case .add(let add) = before.action {
				identity = add.identity
			} else {
				identity = nil
			}
			(reuse, change) = (before.id, proposed)
		}
		switch change {
		case .add(let payload):
			if Eligibility.refusal(ofAddOn: payload.date, today: today) != nil {
				throw .pastDate(payload.date)
			}
			return ProposedTarget(
				reuse: reuse,
				action: .add(
					AddedWorkout(payload: payload, identity: identity ?? CalendarWriteID())))
		case .edit(let event, let patch):
			let snapshot = try await reviewed(event, destination: patch.date, reads, today)
			if case .replacing(let before, _) = item, before.desires(patch, on: snapshot) {
				throw .unchanged(before.id)
			}
			return ProposedTarget(
				reuse: reuse,
				action: .edit(EditedWorkout(target: .reviewed(event, snapshot), patch: patch)))
		case .delete(let event):
			let snapshot = try await reviewed(event, destination: nil, reads, today)
			return ProposedTarget(
				reuse: reuse, action: .delete(DeletedWorkout(target: .reviewed(event, snapshot))))
		}
	}

	private static func reviewed(
		_ event: EventID, destination: CivilDate?, _ reads: any CalendarReads, _ today: CivilDate
	) async throws(PreparationRefusal) -> WorkoutSnapshot {
		let current: CalendarEvent
		let snapshot: WorkoutSnapshot
		do {
			current = try await reads.fetchEvent(id: event)
			snapshot = try current.snapshot
		} catch {
			throw .targetUnreadable(event)
		}
		if let refusal = Eligibility.refusal(of: current, destination: destination, today: today) {
			throw .ineligible(event, refusal)
		}
		return snapshot
	}

	private static func kept(around targets: [ProposedTarget], reads: any CalendarReads)
		async throws(PreparationRefusal) -> [KeptWorkout]
	{
		let actions = targets.map(\.action)
		let targeted = Set(actions.compactMap(\.event))
		var dates: [CivilDate] = []
		for date in actions.map(\.affectedDate) where !dates.contains(date) {
			dates.append(date)
		}
		var kept: [KeptWorkout] = []
		for date in dates {
			let listed: [CalendarEvent]
			do {
				listed = try await reads.listEvents(in: .day(date))
			} catch {
				throw .keptUnreadable(date)
			}
			kept += listed.filter { $0.category == "WORKOUT" && !targeted.contains($0.id) }.map {
				KeptWorkout(
					name: $0.name, date: date,
					durationMinutes: $0.movingTime.map(ReviewProjection.minutes(ofSeconds:)))
			}
		}
		return kept
	}
}

private enum PlannedChange {
	case proposed(ProposedChange)
	case replacing(ReviewChange, with: ProposedChange)
	case carried(ReviewChange)

	var event: EventID? {
		switch self {
		case .proposed(let change), .replacing(_, let change):
			switch change {
			case .add: nil
			case .edit(let event, _), .delete(let event): event
			}
		case .carried(let change): change.action.event
		}
	}
}

extension ChangeAction {
	fileprivate var event: EventID? {
		switch self {
		case .add: nil
		case .edit(let edit): edit.target.event
		case .delete(let delete): delete.target.event
		}
	}

	fileprivate var affectedDate: CivilDate {
		switch self {
		case .add(let add): add.payload.date
		case .edit(let edit): edit.patch.date ?? edit.target.date
		case .delete(let delete): delete.target.date
		}
	}
}

extension ReviewChange {
	fileprivate func desires(_ patch: WorkoutPatch, on current: WorkoutSnapshot) -> Bool {
		guard case .edit(let edit) = action, case .reviewed(_, let earlier) = edit.target else {
			return false
		}
		return edit.patch.applied(to: earlier) == patch.applied(to: current)
			&& edit.patch.authoredSteps == patch.authoredSteps
	}
}

extension WorkoutPatch {
	fileprivate func revised(by next: WorkoutPatch, on target: ReviewedTarget) -> WorkoutPatch {
		let merged = WorkoutPatch(
			date: next.date ?? date, name: next.name ?? name,
			durationSeconds: next.durationSeconds ?? durationSeconds,
			description: next.description ?? description,
			trainingLoad: next.trainingLoad ?? trainingLoad,
			workoutDocument: next.authoredSteps == nil
				? next.workoutDocument ?? workoutDocument : nil,
			authoredSteps: next.authoredSteps)
		guard next.authoredSteps == nil, merged.keepsContent(of: self, on: target) else {
			return merged
		}
		return WorkoutPatch(
			date: merged.date, name: merged.name, durationSeconds: merged.durationSeconds,
			description: merged.description, trainingLoad: merged.trainingLoad,
			workoutDocument: merged.workoutDocument, authoredSteps: authoredSteps)
	}

	private func keepsContent(of before: WorkoutPatch, on target: ReviewedTarget) -> Bool {
		guard case .reviewed(_, let reviewed) = target else {
			return durationSeconds == before.durationSeconds && description == before.description
				&& workoutDocument == before.workoutDocument
		}
		let candidate = applied(to: reviewed)
		let earlier = before.applied(to: reviewed)
		return candidate.durationSeconds == earlier.durationSeconds
			&& candidate.description == earlier.description
			&& candidate.structure == earlier.structure
	}
}

extension ReviewedTarget {
	fileprivate var date: CivilDate {
		switch self {
		case .reviewed(_, let snapshot): snapshot.date
		case .upgradedWithoutSnapshot(_, let date): date
		}
	}
}
