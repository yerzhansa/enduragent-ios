import Foundation

package actor SingleProposalReviews: WorkoutReviews {
	private let ledger: Ledger
	private let clock: any Clock
	private let diagnostics: DiagnosticsLog
	private let training: @Sendable () async throws(AccessUnavailable) -> TrainingConnection
	private var deliveries: [ChatID: Delivery] = [:]
	private var closed: Set<ChangeSetID> = []

	package init(
		ledger: Ledger,
		clock: any Clock,
		diagnostics: DiagnosticsLog,
		training: @escaping @Sendable () async throws(AccessUnavailable) -> TrainingConnection
	) {
		self.ledger = ledger
		self.clock = clock
		self.diagnostics = diagnostics
		self.training = training
	}

	package func snapshot(chat: ChatID) async throws(LedgerFailure) -> ReviewSnapshot? {
		let previous = deliveries[chat]?.ref
		let live = try await ProposalPolicy.live(chatId: chat, ledger: ledger, now: clock.now)
		let current: TrainingAccount? = if live != nil { await currentAccount() } else { nil }
		guard deliveries[chat]?.ref == previous else { return try await snapshot(chat: chat) }
		guard let live else {
			deliveries[chat] = nil
			return nil
		}
		guard !closed.contains(ChangeSetID(ulid: live.ulid)) else {
			deliveries[chat] = nil
			return nil
		}
		let delivery = delivery(for: live, in: chat)
		let changed = current.map { !Self.permits(live.account.authority(under: $0)) } ?? false
		let notice: ReviewNotice? =
			if delivery.authority == .readOnly {
				AthleteNotices.earlierVersion
			} else if changed {
				AthleteNotices.accountChanged
			} else {
				nil
			}
		let card = ReviewCard(live.body)
		return ReviewSnapshot(
			ref: delivery.ref,
			cards: [card],
			kept: [],
			totals: ReviewTotals([card]),
			receipts: [],
			notice: notice,
			controls: changed ? .none : delivery.controls,
			authority: delivery.authority
		)
	}

	package func decide(_ decision: ReviewDecision, chat: ChatID) async -> ReviewOutcome {
		guard decision.ref.chat == chat, var delivery = deliveries[chat],
			delivery.ref == decision.ref
		else {
			return .staleControl
		}
		switch decision {
		case .presented:
			if delivery.authority == .thisDevice {
				delivery.secret = delivery.secret ?? UUID()
			}
		case .presentationFailed:
			delivery.secret = nil
		case .showAgain:
			delivery.ref = ReviewRef(
				chat: chat, set: delivery.ref.set, revision: delivery.ref.revision, delivery: UUID()
			)
			delivery.secret = nil
		case .approve(let token), .cancel(let token):
			guard !delivery.busy, delivery.secret == token.secret else { return .staleControl }
			delivery.busy = true
			deliveries[chat] = delivery
			let outcome: ReviewOutcome
			if case .approve = decision {
				outcome = await approve(token)
			} else {
				outcome = await cancel(token)
			}
			finish(token.ref, outcome)
			return outcome
		case .retryRemaining, .checkAgain:
			return .staleControl
		}
		deliveries[chat] = delivery
		return .presentationRecorded
	}

	private func approve(_ token: ReviewControlToken) async -> ReviewOutcome {
		let live: LiveProposal
		switch await liveProposal(for: token.ref) {
		case .found(let found): live = found
		case .refused(let outcome): return outcome
		}
		let connection: TrainingConnection
		do {
			connection = try await training()
		} catch {
			return .blocked(.cannotVerify)
		}
		guard Self.permits(live.account.authority(under: connection.account)) else {
			return .blocked(.accountChanged)
		}
		let stamp = await stamp(token.ref, account: connection.account)
		do {
			try await ProposalPolicy.clear(live, reason: .executed, ledger: ledger, stamp: stamp)
		} catch {
			return .storageUnavailable
		}
		let card = ReviewCard(live.body)
		let eventId: String
		do {
			eventId = try await write(live.body.toolInput, on: connection.client)
		} catch {
			diagnostics.record(
				.toolFailed(
					stamp.attempt, live.body.tool.toolName, failure: ToolFault(error)))
			guard let failure = Self.stopped(error) else {
				return .uncertain(done: [], unresolved: card)
			}
			return .partiallyApplied(done: [], stoppedAt: card, failure: failure)
		}
		await note(live.body, stamp: stamp)
		return .applied([ReviewReceipt(index: card.index, result: .confirmed(eventId: eventId))])
	}

	private func cancel(_ token: ReviewControlToken) async -> ReviewOutcome {
		let live: LiveProposal
		switch await liveProposal(for: token.ref) {
		case .found(let found): live = found
		case .refused(let outcome): return outcome
		}
		do {
			try await ProposalPolicy.clear(
				live, reason: .canceled, ledger: ledger,
				stamp: await stamp(token.ref, account: live.account))
		} catch {
			return .storageUnavailable
		}
		return .canceled(kept: [])
	}

	private func liveProposal(for ref: ReviewRef) async -> LiveLookup {
		let found: LiveProposal?
		do {
			found = try await ProposalPolicy.live(chatId: ref.chat, ledger: ledger, now: clock.now)
		} catch {
			return .refused(.storageUnavailable)
		}
		guard let found, ChangeSetID(ulid: found.ulid) == ref.set else {
			return .refused(.staleControl)
		}
		return .found(found)
	}

	private func finish(_ ref: ReviewRef, _ outcome: ReviewOutcome) {
		switch outcome {
		case .blocked, .storageUnavailable:
			if deliveries[ref.chat]?.ref == ref {
				deliveries[ref.chat]?.busy = false
			}
		case .applied, .partiallyApplied, .uncertain, .canceled, .changedSinceReview, .staleControl,
			.presentationRecorded:
			closed.insert(ref.set)
			if deliveries[ref.chat]?.ref == ref {
				deliveries[ref.chat] = nil
			}
		}
	}

	private func delivery(for live: LiveProposal, in chat: ChatID) -> Delivery {
		let set = ChangeSetID(ulid: live.ulid)
		if let existing = deliveries[chat], existing.ref.set == set {
			return existing
		}
		let minted = Delivery(
			authority: live.cause == .legacy ? .readOnly : .thisDevice,
			ref: ReviewRef(
				chat: chat, set: set, revision: ChangeSetRevision(rawValue: 1), delivery: UUID()))
		deliveries[chat] = minted
		return minted
	}

	private static func permits(_ authority: AccountAuthority) -> Bool {
		switch authority {
		case .same, .sameAthlete: true
		case .changed, .unverifiable: false
		}
	}

	private func currentAccount() async -> TrainingAccount? {
		do {
			return try await training().account
		} catch {
			switch error {
			case .notConfigured, .secureStorageLocked, .secureStorageUnavailable,
				.malformedStoredCredential:
				return nil
			}
		}
	}

	private func stamp(_ ref: ReviewRef, account: TrainingAccount) async -> OperationStamp {
		OperationStamp(
			operation: .workoutChangeSet(ref.set, ref.revision),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(account: account, zone: AthleteCalendar(clock: clock).deviceZone)
		)
	}

	private func note(_ body: ProposalBody, stamp: OperationStamp) async {
		do {
			_ = try await ledger.commit(
				synced: [
					.reviewApplied(
						ReviewAppliedBody(
							chatId: body.chatId, summary: ReviewSummary(body.toolInput)))
				],
				stamp: stamp)
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
		}
	}

	private func write(_ input: GatedToolInput, on intervals: any IntervalsClient) async throws
		-> String
	{
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		switch input {
		case .createWorkout(let date, let workout):
			try IntervalsPolicy.rejectPastCreationDate(date, today: today)
			let serialized = try IntervalsSerializer.serialize(workout)
			let event = try await intervals.createChatEvent(
				ChatCalendarCreate(
					date: date,
					name: workout.name,
					description: serialized.description,
					type: .ride,
					externalId: IntervalsSerializer.chatExternalId(date: date, name: workout.name),
					tags: [IntervalsPolicy.coachTag]
				))
			return String(event.id.rawValue)
		case .createStrengthWorkout(let date, let name, let description):
			try IntervalsPolicy.rejectPastCreationDate(date, today: today)
			let event = try await intervals.createChatEvent(
				ChatCalendarCreate(
					date: date,
					name: name,
					description: description,
					type: .weightTraining,
					externalId: IntervalsSerializer.chatExternalId(
						date: date, name: "strength \(name)"),
					tags: [IntervalsPolicy.coachTag]
				))
			return String(event.id.rawValue)
		case .deleteWorkout(let eventId):
			try await intervals.deleteEvent(id: eventId)
			return String(eventId.rawValue)
		case .updateWorkout(let update):
			let event = try await intervals.updateEvent(
				id: update.eventId, name: update.name, description: update.description,
				date: update.date)
			return String(event.id.rawValue)
		case .planSave:
			throw IntervalsError(
				code: "not_implemented", details: "Saving a plan is not available yet.")
		}
	}

	private static func stopped(_ error: any Error) -> TrainingFailure? {
		if error is InvalidWorkout {
			return .requestRejected
		}
		guard let intervals = error as? IntervalsError else { return nil }
		if intervals.status != nil {
			return TrainingFailure(intervals)
		}
		switch intervals.code {
		case "invalid_json", "network": return nil
		default: return .requestRejected
		}
	}
}

private struct Delivery {
	let authority: ReviewAuthority
	var ref: ReviewRef
	var secret: UUID?
	var busy = false

	var controls: ReviewControls {
		guard !busy, let secret else { return .none }
		return .approveOrCancel(ReviewControlToken(ref: ref, secret: secret))
	}
}

private enum LiveLookup {
	case found(LiveProposal)
	case refused(ReviewOutcome)
}

extension ReviewCard {
	fileprivate init(_ body: ProposalBody) {
		let instructions: ReviewInstructions
		if case .createWorkout(_, let workout) = body.toolInput {
			instructions = ReviewInstructions(content: .cycling(workout))
		} else {
			instructions = ReviewInstructions(content: .supplied(body.description))
		}
		let action: Action
		let name: ReviewSummary
		let date: CivilDate?
		switch body.toolInput {
		case .createWorkout(let day, let workout):
			(action, name, date) = (.add, .supplied(workout.name), day)
		case .createStrengthWorkout(let day, let title, _):
			(action, name, date) = (.add, .supplied(title), day)
		case .updateWorkout(let update):
			(action, name, date) = (
				.edit(previousName: nil),
				update.name.map(ReviewSummary.supplied) ?? ReviewSummary(body.toolInput),
				update.date
			)
		case .deleteWorkout:
			(action, name, date) = (.delete, ReviewSummary(body.toolInput), nil)
		case .planSave:
			(action, name, date) = (.add, ReviewSummary(body.toolInput), nil)
		}
		self.init(
			index: 0, action: action, name: name, date: date, chart: nil,
			instructions: instructions,
			durationMinutes: nil, estimatedLoad: nil)
	}
}

extension ReviewTotals {
	fileprivate init(_ cards: [ReviewCard]) {
		var additions = 0
		var edits = 0
		var deletions = 0
		for card in cards {
			switch card.action {
			case .add: additions += 1
			case .edit: edits += 1
			case .delete: deletions += 1
			}
		}
		self.init(additions: additions, edits: edits, deletions: deletions, durationMinutes: nil)
	}
}
