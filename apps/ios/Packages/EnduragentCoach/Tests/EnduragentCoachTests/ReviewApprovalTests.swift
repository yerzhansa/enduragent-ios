import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewApprovalTests {
	enum DeadToken: String, CaseIterable, CustomTestStringConvertible {
		case renewed, consumed, canceled, otherChat

		var testDescription: String { rawValue }
	}

	enum BlockedTarget: String, CaseIterable, CustomTestStringConvertible {
		case lostProvenance, gone, unreadable, otherAccount, pastAdd

		var testDescription: String { rawValue }

		var stage: Stage {
			switch self {
			case .lostProvenance: .waiting(.blocked(.coachOnly))
			case .gone: .waiting(.blocked(.cannotVerify))
			case .unreadable: .waiting(.approval(.couldNotCheck))
			case .otherAccount: .waiting(.blocked(.accountChanged))
			case .pastAdd: .waiting(.blocked(.pastProtected))
			}
		}
	}

	@Test func approvalAfterAnotherTurnRunsTheSavedReviewWithNoModelRequest() async throws {
		let turns = ReviewTurns()
		let kept = PreparationFixture.workout(
			203, on: "1998-09-11", name: "Easy spin", owned: false, minutes: 45)
		turns.intervals.events.append(kept)
		let calendar = ScriptedCalendar(turns.intervals)
		let coach = await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store,
			clock: turns.clock, tools: .workoutReview)
		let review = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(.approveOrCancel, let token) = try #require(
				try await coach.desk.snapshot(chat: .main)
			).controls
		else {
			Issue.record("the committed review never armed Approve")
			return
		}
		turns.script([.text("Thursday stays easy."), .finish(reason: .stop)])
		let later = try #require(
			try await coach.send(draft("Is Thursday still easy?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: later, in: .main))
		let modelRequests = turns.transport.requests.count

		let outcome = await coach.desk.decide(.approve(token))

		guard case .completed(let receipts) = outcome else {
			Issue.record("approval ended \(outcome)")
			return
		}
		#expect(receipts.count == 4)
		#expect(calendar.writes == review.work.remaining.map(DeskRig.request))
		#expect(turns.transport.requests.count == modelRequests)
		#expect(turns.intervals.events.first { $0.id == kept.id } == kept)
		#expect(try await turns.head(of: coach).1?.stage == .completed)
	}

	@Test func aHangingWriteLeavesStopAndANewMessageWorkingAndSendsNothingBesideIt()
		async throws
	{
		let turns = ReviewTurns()
		let calendar = ScriptedCalendar(turns.intervals)
		let held = Gate()
		defer { held.release() }
		calendar.answer { _, _ in
			await held.wait()
			return nil
		}
		let coach = await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store,
			clock: turns.clock, tools: .workoutReview)
		_ = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(.approveOrCancel, let token) = try #require(
				try await coach.desk.snapshot(chat: .main)
			).controls
		else {
			Issue.record("the committed review never armed Approve")
			return
		}
		let approving = Task { await coach.desk.decide(.approve(token)) }
		try await waitUntil { calendar.writes.count == 1 }

		let stopped: Void? = try await beforeDeadline(within: .hangGuard) {
			await coach.stop(.main)
		}
		#expect(stopped != nil)
		_ = try await turns.reply(
			after: [turns.prepare(ReviewTurns.oneRide)], on: coach, asking: "Add another ride")

		#expect(try turns.toolData().first?.objectFields["error"] == .string("review_running"))
		#expect(calendar.writes.count == 1)
		held.release()
		let outcome = try await beforeDeadline(within: .hangGuard) { await approving.value }
		guard case .completed(let receipts) = outcome else {
			Issue.record("the held approval ended \(String(describing: outcome))")
			return
		}
		#expect(receipts.count == 1)
		#expect(calendar.writes.count == 1)
	}

	@Test func theMixedReviewSendsEachReviewedRequestInCardOrderAndPublishesItsOutcome()
		async throws
	{
		let rig = DeskRig()
		let kept = try rig.event(203)
		let review = try rig.mixed()
		try await rig.save(review)
		let desk = try rig.desk()

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		#expect(rig.calendar.writes == review.work.remaining.map(DeskRig.request))
		#expect(
			outcome
				== .completed(
					zip(0..., [204, 205, 201, 202]).map { index, event in
						ReviewReceipt(index: index, progress: .saved(EventID(rawValue: event)))
					}))
		let head = try #require(try await rig.head().1)
		#expect(head.stage == .completed)
		#expect(
			head.work.finished.map(\.result).allSatisfy {
				if case .saved = $0 { true } else { false }
			})
		let published = try await rig.outcomes()
		#expect(published.map(\.ending) == [.completed])
		#expect(published.first?.lines.map(\.result) == Array(repeating: .saved, count: 4))
		#expect(try rig.event(203) == kept)
	}

	@Test func theClaimIsSavedBeforePreflightReadsTheCalendar() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let seen = rig.watchHeads { $0 == .read }

		_ = await desk.decide(.approve(try await rig.token(on: desk)))

		let first = try #require(seen.all.first)
		#expect(first.isClaimOnly)
	}

	@Test func aClaimThatIsNotSavedReadsAndSendsNothingAndKeepsTheToken() async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let rig = DeskRig(store: faults)
		let saved = try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		try faults.failAppend(ofKind: "workoutReview", skipping: 0)

		#expect(await desk.decide(.approve(token)) == .storageUnavailable)

		#expect(rig.calendar.calls.isEmpty)
		#expect(try await rig.head().0 == saved)
		guard case .completed = await desk.decide(.approve(token)) else {
			Issue.record("the kept token did not run the review")
			return
		}
		#expect(rig.calendar.writes.count == 4)
	}

	@Test(arguments: DeadToken.allCases)
	func aDeadTokenSendsNothing(_ dead: DeadToken) async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		let used: ReviewControlToken
		switch dead {
		case .renewed:
			#expect(await desk.decide(.showAgain(token.ref)) == .presentationRecorded)
			used = token
		case .consumed:
			_ = await desk.decide(.approve(token))
			used = token
		case .canceled:
			_ = await desk.decide(.cancel(token))
			used = token
		case .otherChat:
			used = ReviewControlToken(
				ref: ReviewRef(
					chat: "elsewhere", review: token.ref.review, revision: token.ref.revision,
					delivery: token.ref.delivery),
				secret: token.secret)
		}
		let writes = rig.calendar.writes.count
		let records = try await rig.chain().count
		let newer = dead == .renewed ? try await desk.snapshot(chat: .main)?.ref : nil

		#expect(await desk.decide(.approve(used)) == .staleControl(newer: newer))

		#expect(rig.calendar.writes.count == writes)
		#expect(try await rig.chain().count == records)
	}

	@Test func afterARefreshTheOldTokenSendsNothingAndTheNewerRevisionRuns() async throws {
		let rig = DeskRig()
		try await rig.save(
			try PreflightFixture.review([
				PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID()),
				try PreflightFixture.edit(try rig.event(201), PreflightFixture.patch(minutes: 75)),
			]))
		let desk = try rig.desk()
		let old = try await rig.token(on: desk)
		rig.base.events[0].movingTime = 50 * 60
		guard case .refreshed = await desk.decide(.approve(old)) else {
			Issue.record("the changed target did not refresh the review")
			return
		}

		guard case .staleControl(let newer?) = await desk.decide(.approve(old)) else {
			Issue.record("the old token did not name the refreshed revision")
			return
		}
		#expect(newer.revision == ReviewRevision(rawValue: 2))
		#expect(rig.calendar.writes.isEmpty)
		let refreshed = try #require(try await desk.snapshot(chat: .main))
		#expect(refreshed.ref == newer)

		guard case .completed = await desk.decide(.approve(try await rig.token(on: desk))) else {
			Issue.record("the refreshed review did not run")
			return
		}
		#expect(rig.calendar.writes.count == 2)
	}

	@Test func aWrongActionSendsNothingAndLeavesTheTokenUsable() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		let records = try await rig.chain().count

		#expect(await desk.decide(.tryAgain(token)) == .wrongAction)

		#expect(rig.calendar.calls.isEmpty)
		#expect(try await rig.chain().count == records)
		guard case .completed = await desk.decide(.approve(token)) else {
			Issue.record("the token stopped working after a wrong action")
			return
		}
		#expect(rig.calendar.writes.count == 4)
	}

	@Test func aSecondTapAfterTheRunSendsNothing() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)

		let first = await desk.decide(.approve(token))
		let second = await desk.decide(.approve(token))

		guard case .completed = first else {
			Issue.record("the first tap ended \(first)")
			return
		}
		#expect(second == .staleControl(newer: nil))
		#expect(rig.calendar.writes.count == 4)
		let chain = try await rig.chain()
		#expect(chain.count == 7)
		#expect(chain.filter(\.isClaimOnly).count == 1)
	}

	@Test func twoConcurrentDeliveriesOfOneTokenRunTheReviewOnce() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)

		async let first = desk.decide(.approve(token))
		async let second = desk.decide(.approve(token))
		let outcomes = await [first, second]

		#expect(outcomes.filter { $0 == .staleControl(newer: nil) }.count == 1)
		#expect(outcomes.contains { if case .completed = $0 { true } else { false } })
		#expect(rig.calendar.writes.count == 4)
		let chain = try await rig.chain()
		#expect(chain.count == 7)
		#expect(chain.filter(\.isClaimOnly).count == 1)
	}

	@Test(arguments: BlockedTarget.allCases)
	func aBlockedVerdictSendsNothing(_ target: BlockedTarget) async throws {
		let rig = DeskRig()
		try await rig.save(
			try PreflightFixture.review([
				PreflightFixture.ride(
					on: target == .pastAdd ? "1998-09-07" : "1998-09-09",
					identity: CalendarWriteID()),
				try PreflightFixture.delete(try rig.event(202)),
			]))
		switch target {
		case .lostProvenance:
			rig.base.events[1].tags = []
			rig.base.events[1].coachCreated = false
		case .gone:
			rig.base.events.remove(at: 1)
		case .unreadable:
			rig.base.unreadableEvents = [EventID(rawValue: 202)]
		case .otherAccount, .pastAdd:
			break
		}
		let desk = try rig.desk(
			athlete: target == .otherAccount ? "i2002" : "i1001")

		_ = await desk.decide(.approve(try await rig.token(on: desk)))

		#expect(rig.calendar.writes.isEmpty)
		#expect(try await rig.head().1?.stage == target.stage)
	}

	@Test func aCompletedRunsTokenSendsNothingAfterARelaunch() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		_ = await desk.decide(.approve(token))
		let records = try await rig.chain().count
		let relaunched = try rig.desk()

		#expect(await relaunched.decide(.approve(token)) == .staleControl(newer: nil))
		#expect(await relaunched.decide(.cancel(token)) == .staleControl(newer: nil))

		#expect(rig.calendar.writes.count == 4)
		#expect(try await rig.chain().count == records)
	}
}
