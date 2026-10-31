import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension ReviewRecoveryTests {
	enum MixedAppend: Int, CaseIterable, CustomTestStringConvertible {
		case claim, rideAttempt, strengthAttempt, editAttempt, deleteAttempt, completed, summary

		var testDescription: String { String(describing: self) }

		var writesBefore: Int {
			switch self {
			case .claim, .rideAttempt: 0
			case .strengthAttempt: 1
			case .editAttempt: 2
			case .deleteAttempt: 3
			case .completed, .summary: 4
			}
		}

		func resumed(_ changes: [ReviewChange]) -> (Stage, [FinishedTag]) {
			let saved = zip(changes, [204, 205, 201]).map { FinishedTag($0, .saved($1)) }
			switch self {
			case .claim: return (.waiting(.approval(.prepared)), [])
			case .rideAttempt: return (.waiting(.approval(.interruptedBeforeWriting)), [])
			case .strengthAttempt:
				return (.waiting(.tryAgain(.settled)), [FinishedTag(changes[0], .seen(204))])
			case .editAttempt:
				return (
					.waiting(.tryAgain(.settled)), [saved[0], FinishedTag(changes[1], .seen(205))]
				)
			case .deleteAttempt:
				return (
					.waiting(.tryAgain(.settled)),
					Array(saved.prefix(2)) + [FinishedTag(changes[2], .seen(201))]
				)
			case .completed: return (.completed, saved + [FinishedTag(changes[3], .gone)])
			case .summary:
				return (.completed, saved + [FinishedTag(changes[3], .saved(202))])
			}
		}
	}

	enum RecoverRace: String, CaseIterable, CustomTestStringConvertible {
		case oneCall, twoCallsOnOneDesk, twoDesks, killInsideOne

		var testDescription: String { rawValue }
	}

	@Test(arguments: MixedAppend.allCases)
	func aFailedAppendShowsTheStorageNoticeUntilTheNextRecoverResumesTheRun(
		_ failing: MixedAppend
	) async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let rig = DeskRig(store: faults)
		let review = try rig.mixed()
		try await rig.save(review)
		rig.calendar.answer { [rig] _, write in await rig.keep(write) }
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		switch failing {
		case .summary: try faults.failAppend(ofKind: "reviewOutcome", skipping: 0)
		default: try faults.failAppend(ofKind: "workoutReview", skipping: failing.rawValue)
		}

		#expect(await desk.decide(.approve(token)) == .storageUnavailable)

		let stalled = try #require(try await desk.snapshot(chat: .main))
		guard case .storageUnavailable(_, .none) = stalled.state else {
			Issue.record("the stopped run showed \(stalled.state)")
			return
		}
		#expect(stalled.notice?.kind == .storageUnavailable)
		#expect(rig.calendar.writes.count == failing.writesBefore)
		let calls = rig.calendar.calls.count

		await desk.recover()

		let (stage, finished) = failing.resumed(review.work.remaining)
		let head = try #require(try await rig.head().1)
		#expect(head.stage == stage)
		#expect(head.work.finished.map(FinishedTag.init) == finished)
		#expect(rig.calendar.writes.count == failing.writesBefore)
		let settles = [.strengthAttempt, .editAttempt, .deleteAttempt, .completed].contains(failing)
		#expect(rig.calendar.calls.count - calls == (settles ? 1 : 0))
		switch stage {
		case .completed:
			#expect(try await rig.outcomes().map(\.ending) == [.completed])
			#expect(try await desk.snapshot(chat: .main) == nil)
		default:
			guard case .available = try #require(try await desk.snapshot(chat: .main)).state else {
				Issue.record("the resumed review still shows the storage notice")
				return
			}
		}
	}

	@Test(arguments: RecoverRace.allCases)
	func recoversAtOnceOrAKillInsideOneEndInTheHeadOfOneCall(_ race: RecoverRace) async throws {
		let rig = DeskRig()
		let review = try PreflightFixture.review([
			rig.strength(on: "1998-09-12"), try ChangeKind.add.action(on: rig),
			rig.strength(on: "1998-09-14"),
		])
		try await rig.save(review)
		try await rig.leaveUnconfirmed(at: 1)
		let records = try await rig.records()
		let calendars = [ScriptedCalendar(rig.base), ScriptedCalendar(rig.base)]
		let first = try rig.desk(calendar: calendars[0])
		switch race {
		case .oneCall:
			await first.recover()
		case .twoCallsOnOneDesk:
			async let one: Void = first.recover()
			async let two: Void = first.recover()
			_ = await (one, two)
		case .twoDesks:
			let second = try rig.desk(calendar: calendars[1])
			async let one: Void = first.recover()
			async let two: Void = second.recover()
			_ = await (one, two)
		case .killInsideOne:
			let dying = FaultInjectingRecordLog(wrapping: rig.store)
			dying.refuseEveryAppend(after: 0)
			await (try rig.desk(over: dying, calendar: calendars[1])).recover()
			await first.recover()
		}

		let changes = review.work.remaining
		let head = try #require(try await rig.head().1)
		#expect(head.stage == .waiting(.tryAgain(.settled)))
		#expect(
			head.work.finished.map(FinishedTag.init) == [
				FinishedTag(changes[0], .saved(204)), FinishedTag(changes[1], .seen(205)),
			])
		#expect(head.work.remaining == [changes[2]])
		#expect(try await rig.records() == records + 1)
		#expect(calendars.map(\.writes.count) == [0, 0])
	}

	@Test func aSecondDeskRecoveringDuringALiveSendLeavesOneChainAndOneEvent() async throws {
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		let held = HeldCall()
		let live = ScriptedCalendar(rig.base)
		live.answer { [rig] index, write in
			let answer = await rig.keep(write)
			if index == 1 { await held.hold() }
			return answer
		}
		let first = try rig.desk(calendar: live)
		let token = try await rig.token(on: first)
		let run = Task { await first.decide(.approve(token)) }
		try await held.waitUntilReached()
		let recovering = ScriptedCalendar(rig.base)

		await (try rig.desk(calendar: recovering)).recover()
		held.release()

		#expect(await run.value == .staleControl(newer: nil))
		let changes = review.work.remaining
		guard case .add(let strength) = changes[1].action else {
			Issue.record("the second change of the mixed review is not an add")
			return
		}
		#expect(live.writes == changes.prefix(2).map(DeskRig.request))
		#expect(recovering.writes.isEmpty)
		#expect(recovering.calls == [.read])
		#expect(rig.base.events.filter { $0.externalId == strength.identity.externalID }.count == 1)
		let chain = try await rig.chain()
		#expect(chain.count == 5)
		#expect(chain.prefix(4).compactMap(\.sendingChange) == changes.prefix(2).map(\.id))
		let head = try #require(chain.last)
		#expect(head.stage == .waiting(.tryAgain(.settled)))
		#expect(
			head.work.finished.map(FinishedTag.init) == [
				FinishedTag(changes[0], .saved(204)), FinishedTag(changes[1], .seen(205)),
			])
	}

	@Test(arguments: [true, false])
	func aChangeLeftUnconfirmedByAnEndedLeaseIsSettledByTheNextRecover(landed: Bool) async throws {
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		let host = rig.host
		rig.calendar.answer { [rig] index, write in
			guard index == 1 else { return await rig.keep(write) }
			if landed { _ = await rig.keep(write) }
			Task { await host.expire(.systemExpired) }
			do {
				try await waitUntil { Task.isCancelled }
			} catch is CancellationError {
				return .lost(.canceled)
			} catch {
				Issue.record(error, "waiting for the lease to end failed")
			}
			return .lost(.canceled)
		}
		let desk = try rig.desk()
		guard case .unconfirmed = await desk.decide(.approve(try await rig.token(on: desk))) else {
			Issue.record("the ended lease did not leave the change unconfirmed")
			return
		}
		#expect(host.leases.map(\.ending) == [.interrupted(.systemExpired)])

		await desk.recover()

		let changes = review.work.remaining
		let head = try #require(try await rig.head().1)
		if landed {
			#expect(head.stage == .waiting(.tryAgain(.settled)))
			#expect(
				head.work.finished.map(FinishedTag.init) == [
					FinishedTag(changes[0], .saved(204)), FinishedTag(changes[1], .seen(205)),
				])
			#expect(head.work.remaining == Array(changes.suffix(2)))
		} else {
			#expect(head.stage == .waiting(.tryAgain(.notSaved(changes[1].id))))
			#expect(head.work.remaining == Array(changes.dropFirst()))
		}
		#expect(rig.calendar.writes == changes.prefix(2).map(DeskRig.request))
	}

	@Test(arguments: BoundHead.allCases)
	func boundWorkIsAPreparingAttemptOrAHeadThatIsNotTerminal(_ bound: BoundHead) async throws {
		let rig = DeskRig()
		let desk = try rig.desk()
		try await bound.save(in: rig, desk: desk)

		#expect(try await desk.holdsBoundWork() == bound.holds)
	}

	@Test func theChangesStreamNamesTheChatWhoseCardTheRecoverChanged() async throws {
		let rig = DeskRig()
		try await rig.save(
			try PreflightFixture.review([
				rig.strength(on: "1998-09-12"), try ChangeKind.edit.action(on: rig),
			]))
		try await rig.leaveUnconfirmed(at: 1)
		let desk = try rig.desk(calendar: ScriptedCalendar(rig.base))

		await desk.recover()

		let changed = try await beforeDeadline(within: .hangGuard) { () -> ChatID? in
			for await chat in desk.changes { return chat }
			return nil
		}
		#expect(changed == .main)
		#expect(try await rig.head().1?.stage == .completed)
	}

	@Test func aFinishedReviewWhoseSummaryFailedIsPublishedOnceBeforeANewReviewReplacesIt()
		async throws
	{
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let rig = DeskRig(store: faults)
		let review = try rig.mixed()
		try await rig.save(review)
		rig.calendar.answer { [rig] _, write in await rig.keep(write) }
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		try faults.failAppend(ofKind: "reviewOutcome", skipping: 0)
		#expect(await desk.decide(.approve(token)) == .storageUnavailable)
		#expect(try await rig.head().1?.stage == .completed)

		let request = try PreparationFixture.request(ReviewTurns.oneRide, today: DeskRig.today)
		guard
			case .drafted = await desk.prepare(
				.success(request), for: PreparationFixture.key, chat: .main,
				binding: testStamp(account: PreflightFixture.account).binding,
				reads: rig.calendar),
			case .committed = await desk.settle(
				PreparationFixture.key, in: .main, ending: .finished)
		else {
			throw UnexpectedReview(detail: "the new review was not committed")
		}
		await desk.recover()

		#expect(
			try await rig.outcomes().filter { $0.review == review.id }.map(\.ending)
				== [.completed])
		#expect(try await rig.head().1?.stage == .waiting(.approval(.prepared)))
	}
}
