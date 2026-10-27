import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TryAgainTests {
	enum Resume: String, CaseIterable, CustomTestStringConvertible {
		case here, relaunched, replaced

		var testDescription: String { rawValue }
	}

	enum OnCalendar: String, CaseIterable, CustomTestStringConvertible {
		case carried, absent

		var testDescription: String { rawValue }
	}

	enum DeadToken: String, CaseIterable, CustomTestStringConvertible {
		case renewed, consumed, canceled, earlierRevision

		var testDescription: String { rawValue }
	}

	@Test(arguments: Resume.allCases)
	func tryAgainReadsTheRemainingTargetsFirstAndSendsOnlyTheUnfinishedChanges(_ resume: Resume)
		async throws
	{
		let rig = DeskRig()
		let kept = try rig.event(203)
		let first = try rig.desk()
		let review = try await rig.stopAfterTwoSaved(on: first)
		let desk = resume == .here ? first : try rig.desk()
		let decision: ReviewDecision
		switch resume {
		case .here, .relaunched:
			decision = .tryAgain(try await rig.tryAgainToken(on: desk))
		case .replaced:
			try await rig.replace(
				with: [
					.edit(EventID(rawValue: 201), PreflightFixture.patch(minutes: 75)),
					.delete(EventID(rawValue: 202)),
				], on: desk)
			decision = .approve(try await rig.token(on: desk))
		}
		let before = rig.calendar.calls.count

		let outcome = await desk.decide(decision)

		let touched = Array(rig.calendar.calls.dropFirst(before))
		let firstRequest = try #require(touched.firstIndex { $0 != .read })
		#expect(firstRequest > 0)
		#expect(
			Array(touched[firstRequest...])
				== review.work.remaining.dropFirst(2).map { .write(DeskRig.request(for: $0)) })
		#expect(
			outcome
				== .completed(
					zip(0..., [204, 205, 201, 202]).map { index, event in
						ReviewReceipt(index: index, progress: .saved(EventID(rawValue: event)))
					}))
		#expect(rig.base.calls.filter(\.isCalendarWrite) == rig.requestsOnce(review))
		try rig.expectReviewedOutcome(of: review, keeping: [kept])
	}

	@Test func aRemainingTargetChangedBeforeTryAgainSendsNothingAndAsksForANewApproval()
		async throws
	{
		let rig = DeskRig()
		let kept = try rig.event(203)
		let desk = try rig.desk()
		let review = try await rig.stopAfterTwoSaved(on: desk)
		let token = try await rig.tryAgainToken(on: desk)
		rig.base.events[0].movingTime = 50 * 60
		let before = rig.calendar.calls.count

		let outcome = await desk.decide(.tryAgain(token))

		guard case .refreshed(let notice) = outcome else {
			Issue.record("the changed remaining target gave \(outcome)")
			return
		}
		let touched = Array(rig.calendar.calls.dropFirst(before))
		#expect(!touched.isEmpty)
		#expect(touched.allSatisfy { $0 == .read })
		#expect(
			notice.sentences(in: displayLocale()) == [
				"Workouts in this review changed in intervals.icu after you reviewed them, so nothing else was changed. Check them again before you approve.",
				"Endurance: duration changed from 60 to 50 minutes.",
			])
		let head = try #require(try await rig.head().1)
		#expect(head.revision == ReviewRevision(rawValue: 2))
		#expect(head.work.finished.map(FinishedTag.init) == rig.savedFirstTwo(of: review))
		let shown = try #require(try await desk.snapshot(chat: .main))
		#expect(shown.notice == notice)
		#expect(
			shown.receipts == [
				ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 204))),
				ReviewReceipt(index: 1, progress: .saved(EventID(rawValue: 205))),
			])
		let approval = try await rig.token(on: desk)
		#expect(
			try await desk.snapshot(chat: .main)?.controls == .armed(.approveOrCancel, approval))

		guard case .completed = await desk.decide(.approve(approval)) else {
			Issue.record("the new approval of the refreshed review did not run")
			return
		}

		#expect(rig.base.calls.filter(\.isCalendarWrite) == rig.requestsOnce(review))
		#expect(try rig.event(201).movingTime == 75 * 60)
		#expect(try rig.event(203) == kept)
	}

	@Test(arguments: OnCalendar.allCases)
	func aRefusedAddIsLookedForByItsExternalIDBeforeItIsSentAgain(_ onCalendar: OnCalendar)
		async throws
	{
		let rig = DeskRig()
		let identity = CalendarWriteID()
		let add = PreflightFixture.ride(on: "1998-09-09", identity: identity)
		let review = try PreflightFixture.review([add])
		try await rig.save(review)
		let desk = try rig.desk()
		rig.calendar.answer { [rig] position, write in
			position == 0 ? .httpStatus(400) : await rig.keep(write)
		}
		guard case .stopped = await desk.decide(.approve(try await rig.token(on: desk))) else {
			Issue.record("the refused add did not stop the run")
			return
		}
		let token = try await rig.tryAgainToken(on: desk)
		if onCalendar == .carried {
			rig.base.events.append(PreflightFixture.carrying(identity, 210, on: "1998-10-09"))
		}
		let before = rig.calendar.calls.count

		let outcome = await desk.decide(.tryAgain(token))

		let touched = Array(rig.calendar.calls.dropFirst(before))
		let window = ReadRange.addWindow(around: "1998-09-09")
		let read = try #require(
			rig.base.calls.firstIndex(of: .events(oldest: window.oldest, newest: window.newest)))
		let head = try #require(try await rig.head().1)
		#expect(head.stage == .completed)
		switch onCalendar {
		case .carried:
			#expect(touched.allSatisfy { $0 == .read })
			#expect(rig.base.calls.filter(\.isCalendarWrite).isEmpty)
			#expect(
				head.work.finished.map(FinishedTag.init) == [
					FinishedTag(review.work.remaining[0], .seen(210))
				])
			#expect(outcome == .completed([ReviewReceipt(index: 0, progress: .seenOnCalendar)]))
		case .absent:
			let sent = CalendarWrite.create(try #require(add.addPayload), identity: identity)
			#expect(touched.filter { $0 != .read } == [.write(sent)])
			#expect(touched.first == .read)
			#expect(rig.calendar.writes == [sent, sent])
			let created = rig.base.calls.filter(\.isCalendarWrite)
			#expect(created == [.createEvent(date: "1998-09-09", externalId: identity.externalID)])
			let request = try #require(rig.base.calls.firstIndex { $0.isCalendarWrite })
			#expect(read < request)
			#expect(rig.base.events.filter { $0.externalId == identity.externalID }.count == 1)
			#expect(
				outcome
					== .completed([
						ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 204)))
					]))
		}
		#expect(try await rig.outcomes().map(\.ending) == [.completed])
	}

	@Test(arguments: DeadToken.allCases)
	func aDeadTryAgainTokenSendsNothing(_ dead: DeadToken) async throws {
		let rig = DeskRig()
		let desk = try rig.desk()
		try await rig.stopAfterTwoSaved(on: desk)
		let token = try await rig.tryAgainToken(on: desk)
		switch dead {
		case .renewed:
			#expect(await desk.decide(.showAgain(token.ref)) == .presentationRecorded)
		case .consumed:
			guard case .completed = await desk.decide(.tryAgain(token)) else {
				Issue.record("the first Try again did not finish the review")
				return
			}
		case .canceled:
			guard case .canceled = await desk.decide(.cancel(token)) else {
				Issue.record("Cancel did not end the review")
				return
			}
		case .earlierRevision:
			try await rig.replace(with: [.delete(EventID(rawValue: 202))], on: desk)
		}
		let calls = rig.calendar.calls.count
		let records = try await rig.records()
		let newer = try await desk.snapshot(chat: .main)?.ref

		#expect(await desk.decide(.tryAgain(token)) == .staleControl(newer: newer))

		#expect(rig.calendar.calls.count == calls)
		#expect(try await rig.records() == records)
		if dead == .earlierRevision {
			#expect(newer?.revision == ReviewRevision(rawValue: 2))
		}
	}

	@Test func aDoubleTapOfTryAgainClaimsOnceAndSendsEachRemainingChangeOnce() async throws {
		let rig = DeskRig()
		let desk = try rig.desk()
		let review = try await rig.stopAfterTwoSaved(on: desk)
		let token = try await rig.tryAgainToken(on: desk)

		async let first = desk.decide(.tryAgain(token))
		async let second = desk.decide(.tryAgain(token))
		let outcomes = await [first, second]

		#expect(outcomes.filter { $0 == .staleControl(newer: nil) }.count == 1)
		#expect(outcomes.contains { if case .completed = $0 { true } else { false } })
		#expect(try await rig.chain().compactMap(\.claimedAction) == [.approve, .tryAgain])
		#expect(rig.base.calls.filter(\.isCalendarWrite) == rig.requestsOnce(review))
	}

	@Test func twoDesksWithTryAgainBehindOneBarrierClaimOnceAndSendEachRemainingChangeOnce()
		async throws
	{
		let barrier = BarrierChainLog(InMemoryRecordLog())
		let rig = DeskRig(store: barrier)
		let phone = try rig.desk()
		let review = try await rig.stopAfterTwoSaved(on: phone)
		let pad = try rig.desk()
		let phoneToken = try await rig.tryAgainToken(on: phone)
		let padToken = try await rig.tryAgainToken(on: pad)
		barrier.arm(readers: 2)

		async let fromPhone = phone.decide(.tryAgain(phoneToken))
		async let fromPad = pad.decide(.tryAgain(padToken))
		let outcomes = await [fromPhone, fromPad]

		#expect(barrier.heldReads == 2)
		#expect(outcomes.filter { $0 == .staleControl(newer: nil) }.count == 1)
		#expect(outcomes.contains { if case .completed = $0 { true } else { false } })
		#expect(try await rig.chain().compactMap(\.claimedAction) == [.approve, .tryAgain])
		#expect(rig.base.calls.filter(\.isCalendarWrite) == rig.requestsOnce(review))
	}
}

extension DeskRig {
	@discardableResult
	func stopAfterTwoSaved(on desk: WorkoutReviewDesk) async throws -> WorkoutReview {
		let review = try mixed()
		try await save(review)
		calendar.answer { [self] position, write in
			position == 2 ? .httpStatus(429) : await keep(write)
		}
		guard case .stopped = await desk.decide(.approve(try await token(on: desk))) else {
			throw UnexpectedReview(detail: "the refused third change did not stop the run")
		}
		calendar.answer { [self] _, write in await keep(write) }
		let head = try #require(try await head().1)
		guard head.work.finished.map(FinishedTag.init) == savedFirstTwo(of: review),
			head.stage == .waiting(.tryAgain(.refused(review.work.remaining[2].id, .rateLimited)))
		else {
			throw UnexpectedReview(detail: "the run did not stop after two saved changes")
		}
		return review
	}

	func savedFirstTwo(of review: WorkoutReview) -> [FinishedTag] {
		[
			FinishedTag(review.work.remaining[0], .saved(204)),
			FinishedTag(review.work.remaining[1], .saved(205)),
		]
	}

	func tryAgainToken(on desk: WorkoutReviewDesk) async throws -> ReviewControlToken {
		let token = try await token(on: desk)
		guard
			try await desk.snapshot(chat: .main)?.controls == .armed(.tryAgainOrCancel, token)
		else {
			throw UnexpectedReview(detail: "the stopped review did not offer Try again")
		}
		return token
	}

	func replace(with changes: [ProposedChange], on desk: WorkoutReviewDesk) async throws {
		let waiting = ReviewBase(of: try #require(try await head().1))
		let key = DraftKey(
			turn: TurnID(ulid: reviewULID(710)), attempt: AttemptID(ulid: reviewULID(711)))
		let reply = await desk.prepare(
			.success(.replace(waiting, changes)), for: key, chat: .main,
			binding: ActionBinding(
				account: PreflightFixture.account, zone: AthleteCalendar(clock: clock).deviceZone),
			reads: calendar)
		guard reply == .drafted(changes: changes.count, base: waiting),
			case .committed = await desk.settle(key, in: .main, ending: .finished)
		else {
			throw UnexpectedReview(detail: "the replacement was not committed")
		}
	}

	func requestsOnce(_ review: WorkoutReview) -> [FakeIntervalsCall] {
		review.work.remaining.map { change in
			switch change.action {
			case .add(let add):
				.createEvent(date: add.payload.date, externalId: add.identity.externalID)
			case .edit(let edit): .updateEvent(edit.target.event)
			case .delete(let delete): .deleteEvent(delete.target.event)
			}
		}
	}

	func expectReviewedOutcome(of review: WorkoutReview, keeping kept: [CalendarEvent]) throws {
		var expected = try kept.map { try CalendarLine($0.snapshot) }
		for change in review.work.remaining {
			switch change.action {
			case .add(let add):
				expected.append(
					CalendarLine(
						date: add.payload.date, name: add.payload.name,
						seconds: add.payload.movingTime))
			case .edit(let edit):
				guard case .reviewed(_, let reviewed) = edit.target else {
					throw UnexpectedReview(detail: "the reviewed edit has no snapshot")
				}
				expected.append(CalendarLine(edit.patch.applied(to: reviewed)))
			case .delete:
				continue
			}
		}
		let actual = try base.events.map { try CalendarLine($0.snapshot) }
		#expect(actual.sorted() == expected.sorted())
	}
}

struct CalendarLine: Comparable {
	let date: CivilDate
	let name: String?
	let seconds: Int?

	init(date: CivilDate, name: String?, seconds: Int?) {
		self.date = date
		self.name = name
		self.seconds = seconds
	}

	init(_ snapshot: WorkoutSnapshot) {
		self.init(date: snapshot.date, name: snapshot.name, seconds: snapshot.durationSeconds)
	}

	static func < (lhs: Self, rhs: Self) -> Bool {
		(lhs.date.rawValue, lhs.name ?? "", lhs.seconds ?? 0)
			< (rhs.date.rawValue, rhs.name ?? "", rhs.seconds ?? 0)
	}
}

extension WorkoutReview {
	var claimedAction: ClaimedAction? {
		guard case .running(let run) = stage, run.sending == nil else { return nil }
		return run.claim.action
	}
}

extension ChangeAction {
	var addPayload: CalendarPayload? {
		if case .add(let add) = self { return add.payload }
		return nil
	}
}
