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

	package func decide(
		_ decision: ReviewDecision, chat: ChatID,
		scope: TurnScope?
	) async -> ReviewOutcome {
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
				let gate: TurnScope
				if let scope {
					gate = scope
				} else {
					gate = TurnScope(
						stamp: await stamp(token.ref, account: .unconnected),
						policy: .npm, ladder: .npm, uptime: clock.uptime)
				}
				outcome = await approve(token, scope: gate)
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

	private func approve(
		_ token: ReviewControlToken, scope: TurnScope
	) async -> ReviewOutcome {
		await scope.reviewing { await self.applyApproval(token, scope: scope) }
	}

	private func applyApproval(
		_ token: ReviewControlToken, scope: TurnScope
	) async -> ReviewOutcome {
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
		guard await scope.beginReview(live) else { return .blocked(.turnStopping) }
		do {
			try await ProposalPolicy.clear(live, reason: .executed, ledger: ledger, stamp: stamp)
			try await recordWrite(live, status: .unverified, stamp: stamp)
		} catch {
			await scope.recordReview(live, outcome: .storageUnavailable)
			return .storageUnavailable
		}
		let outcome = await apply(live, connection: connection, stamp: stamp)
		await scope.recordReview(live, outcome: outcome)
		return outcome
	}

	private func apply(
		_ live: LiveProposal, connection: TrainingConnection, stamp: OperationStamp
	) async -> ReviewOutcome {
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
			await resolveWrite(live, status: .rejected, stamp: stamp)
			return .partiallyApplied(done: [], stoppedAt: card, failure: failure)
		}
		await resolveWrite(live, status: .confirmed, stamp: stamp)
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

	private func resolveWrite(
		_ live: LiveProposal, status: ReviewWriteStatus, stamp: OperationStamp
	) async {
		do {
			try await recordWrite(live, status: status, stamp: stamp)
		} catch {
			diagnostics.record(.reviewOutcomeUnsaved(error))
		}
	}

	private func recordWrite(
		_ live: LiveProposal, status: ReviewWriteStatus, stamp: OperationStamp
	) async throws(LedgerFailure) {
		let origin: OperationStamp
		if case .operation(.turn(let turn), let attempt) = live.cause {
			origin = OperationStamp(
				operation: .turn(turn), attempt: attempt, binding: stamp.binding)
		} else {
			origin = stamp
		}
		var bodies: [SyncedRecordBody] = [
			.reviewWrite(
				ReviewWriteBody(
					chatId: live.body.chatId, review: ChangeSetID(ulid: live.ulid), status: status))
		]
		if status == .confirmed {
			bodies.append(
				.reviewApplied(
					ReviewAppliedBody(
						chatId: live.body.chatId, summary: ReviewSummary(live.body.toolInput))))
		}
		_ = try await ledger.commit(synced: bodies, stamp: origin)
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
