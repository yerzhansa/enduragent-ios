import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

struct LiveCalendarTraining: TrainingClient {
	let calendar: any IntervalsClient

	func profile() async throws -> AthleteProfile { throw Self.calendarOnly }
	func wellness(in range: ReadRange) async throws -> [WellnessDay] { throw Self.calendarOnly }
	func activities(in range: ReadRange) async throws -> ActivityListing {
		throw Self.calendarOnly
	}
	func activity(_ id: ActivityID) async throws -> ActivityDetailRead { throw Self.calendarOnly }
	func streams(of id: ActivityID, channels: StreamChannels) async throws -> StreamSummary {
		throw Self.calendarOnly
	}

	func fetchEvent(id: EventID) async throws -> CalendarEvent {
		try await calendar.fetchEvent(id: id)
	}

	func listEvents(in range: ReadRange) async throws -> [CalendarEvent] {
		try await calendar.listEvents(in: range)
	}

	func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer {
		await calendar.write(write)
	}

	private static var calendarOnly: LiveCheckStop {
		LiveCheckStop(description: "the desk run reads only the calendar")
	}
}

private struct LiveDeskTargets {
	let edited: EventID
	let deleted: EventID
	let kept: CalendarEvent
	let actions: [ChangeAction]
}

extension LiveCalendarRun {
	mutating func reviewThroughTheDesk() async {
		begin("desk review")
		guard let athlete = ledger.athlete.flatMap(IntervalsAthleteID.init(rawValue:)) else {
			fail("nothing was sent: the seed ledger names no athlete")
			return
		}
		guard let targets = await deskTargets() else { return }
		let clock = SystemClock()
		let connection = ConnectionID()
		let account = TrainingAccount.intervals(connection: connection, athlete: athlete)
		let records = Ledger(
			log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let host = ImmediateExecutionHost()
		let training = LiveCalendarTraining(calendar: client)
		let desk = WorkoutReviewDesk(
			ledger: records, clock: clock, diagnostics: DiagnosticsLog(clock: clock),
			training: { _ in
				.connected(
					ConnectedTraining(connection: connection, athlete: athlete, client: training))
			}, host: host)
		let review: WorkoutReview
		let token: ReviewControlToken
		do {
			review = try LiveSendAttempt.review(
				of: targets.actions, account: account, at: clock.now)
			_ = try await records.commit(
				review: review,
				stamp: OperationStamp(
					operation: .workoutReview(review.id, review.revision),
					attempt: AttemptID(ulid: await records.nextULID()),
					binding: ActionBinding(
						account: account, zone: AthleteCalendar(clock: clock).deviceZone)),
				after: .empty)
			token = try await armedToken(on: desk)
		} catch {
			fail("nothing was sent: \(LiveCalendarSweep.describe(error))")
			return
		}
		collect()
		let outcome = await desk.decide(.approve(token))
		let writes = drained().filter { $0.method != "GET" }
		for response in writes {
			note("\(response.request) answered HTTP \(response.status)")
		}
		let expected = [
			"POST \(Self.eventsPath)/bulk?upsert=true&upsertOnUid=false&updatePlanApplied=false",
			"POST \(Self.eventsPath)/bulk?upsert=true&upsertOnUid=false&updatePlanApplied=false",
			"PUT \(Self.eventsPath)/\(targets.edited.rawValue)",
			"DELETE \(Self.eventsPath)/\(targets.deleted.rawValue)",
		]
		if writes.map(\.request) != expected {
			fail("the approval sent \(writes.map(\.request)), not \(expected)")
		}
		await checkSavedRun(of: review, outcome: outcome, in: records)
		checkLease(of: host)
		await checkCalendar(after: review, targets: targets)
	}

	private mutating func deskTargets() async -> LiveDeskTargets? {
		let desk = plan.desk
		guard let edited = await send(desk.edited)?.id,
			let deleted = await send(desk.deleted)?.id,
			let keptID = await send(desk.kept)?.id,
			record(desk.ride), record(desk.strength),
			let editTarget = await reviewed(edited),
			let deleteTarget = await reviewed(deleted)
		else { return nil }
		let kept: CalendarEvent
		do {
			kept = try await client.fetchEvent(id: keptID)
		} catch {
			fail(
				"the read of event \(keptID.rawValue) failed: \(LiveCalendarSweep.describe(error))")
			return nil
		}
		return LiveDeskTargets(
			edited: edited, deleted: deleted, kept: kept,
			actions: [
				.add(AddedWorkout(payload: desk.ride.payload, identity: desk.ride.identity)),
				.add(
					AddedWorkout(payload: desk.strength.payload, identity: desk.strength.identity)),
				.edit(EditedWorkout(target: editTarget, patch: desk.edit)),
				.delete(DeletedWorkout(target: deleteTarget)),
			])
	}

	private func armedToken(on desk: WorkoutReviewDesk) async throws -> ReviewControlToken {
		guard let shown = try await desk.snapshot(chat: .main),
			await desk.decide(.presented(shown.ref)) == .presentationRecorded,
			case .armed(.approveOrCancel, let token)? = try await desk.snapshot(chat: .main)?
				.controls
		else {
			throw LiveCheckStop(description: "the saved review never armed Approve")
		}
		return token
	}

	private mutating func checkSavedRun(
		of review: WorkoutReview, outcome: ReviewOutcome, in records: Ledger
	) async {
		guard case .completed(let receipts) = outcome else {
			fail("the approval ended \(outcome), not completed")
			return
		}
		note("The approval completed with \(receipts.count) receipts.")
		if receipts.count != 4 { fail("the approval gave \(receipts.count) receipts, not 4") }
		do {
			let head = try await records.reviewHead(chat: .main).1
			if head?.stage != .completed {
				fail("the saved review ended at \(head.map { "\($0.stage)" } ?? "nothing")")
			}
			for finished in head?.work.finished ?? [] {
				recordReceipt(of: finished)
			}
			let ending = try await records.reviewOutcomes(chat: .main)[review.id]?.ending
			note("The published outcome ended \(ending.map { "\($0)" } ?? "nowhere").")
			if ending != .completed { fail("no completed outcome was published") }
		} catch {
			fail("the saved review could not be read: \(LiveCalendarSweep.describe(error))")
		}
	}

	private mutating func recordReceipt(of finished: FinishedChange) {
		guard case .saved(let receipt) = finished.result else {
			fail("change \(finished.change.position) finished as \(finished.result), not a Receipt")
			return
		}
		guard case .add(let add) = finished.change.action else { return }
		note(
			"CalendarWriter.classify gave saved for the live create answer of \(add.identity.externalID): a Receipt for event \(receipt.event.rawValue)."
		)
		do {
			try ledger.record(calendar: add.identity.externalID, event: receipt.event)
		} catch {
			fail(
				"the ledger did not record event \(receipt.event.rawValue): \(LiveCalendarSweep.describe(error))"
			)
		}
	}

	private mutating func checkLease(of host: ImmediateExecutionHost) {
		let leases = host.leases
		note(
			"The run took \(leases.count) lease: \(leases.map { "\($0.request.initiatedBy.rawValue), \($0.kind.rawValue), ended \($0.ending.map { "\($0)" } ?? "never")" })"
		)
		if leases.map(\.request) != [LeaseRequest(chat: .main, initiatedBy: .athlete)]
			|| leases.map(\.ending) != [.finished]
		{
			fail("the run did not hold one athlete lease that ended finished")
		}
	}

	private mutating func checkCalendar(after review: WorkoutReview, targets: LiveDeskTargets)
		async
	{
		let desk = plan.desk
		for add in [desk.ride, desk.strength] {
			do {
				let carrying = try await client.listEvents(in: .addWindow(around: add.payload.date))
					.filter { $0.externalId == add.externalID }
				guard carrying.count == 1, let stored = carrying.first else {
					fail("\(carrying.count) events carry \(add.key)'s external_id, not one")
					continue
				}
				report(
					Self.diffs(sent: add, stored: stored), of: add.key,
					in: LiveSave(sentDescription: true, sentStructure: false, stored: stored))
			} catch {
				fail("the window read failed: \(LiveCalendarSweep.describe(error))")
			}
		}
		do {
			let edited = try await client.fetchEvent(id: targets.edited).snapshot
			note("The edited target reads back \(Self.text(edited.durationSeconds)) seconds.")
			if !desk.edit.isApplied(on: edited) { fail("the edit is not on the calendar") }
			let kept = try await client.fetchEvent(id: targets.kept.id)
			if try kept.snapshot != targets.kept.snapshot {
				fail("the kept workout changed")
			} else {
				note("The kept workout \(targets.kept.id.rawValue) is unchanged.")
			}
		} catch {
			fail("the read back failed: \(LiveCalendarSweep.describe(error))")
		}
		do {
			let event = try await client.fetchEvent(id: targets.deleted)
			fail("the deleted target still reads back as event \(event.id.rawValue)")
		} catch let error as IntervalsError where error.status == 404 {
			note("A GET of the deleted target answered 404.")
		} catch {
			fail("a GET of the deleted target failed: \(LiveCalendarSweep.describe(error))")
		}
	}
}
