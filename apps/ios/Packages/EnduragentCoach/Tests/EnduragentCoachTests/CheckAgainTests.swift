import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CheckAgainTests {
	enum OtherStage: String, CaseIterable, CustomTestStringConvertible {
		case approval, tryAgain, blocked

		var testDescription: String { rawValue }
	}

	enum DeadToken: String, CaseIterable, CustomTestStringConvertible {
		case renewed, consumed, canceled, otherChat

		var testDescription: String { rawValue }
	}

	struct Unconfirmed {
		let rig = DeskRig()
		let calendar: ScriptedCalendar
		let changes: [ReviewChange]

		init(_ kind: ChangeKind) async throws {
			let review = try PreflightFixture.review([
				rig.strength(on: "1998-09-12"), try kind.action(on: rig),
				rig.strength(on: "1998-09-14"),
			])
			try await rig.save(review)
			try await rig.leaveUnconfirmed(at: 1)
			calendar = ScriptedCalendar(rig.base)
			changes = review.work.remaining
		}

		func settled(_ kind: ChangeKind) -> [FinishedTag] {
			let landed: FinishedTag.Result =
				switch kind {
				case .add: .seen(205)
				case .edit: .seen(201)
				case .delete: .gone
				}
			return [FinishedTag(changes[0], .saved(204)), FinishedTag(changes[1], landed)]
		}

		func expectStillUnconfirmed() async throws {
			guard case .waiting(.unconfirmed(let attempt)) = try await rig.head().1?.stage else {
				Issue.record("the unconfirmed change was settled by a failed read")
				return
			}
			#expect(attempt.change == changes[1])
		}
	}

	@Test(arguments: ChangeKind.allCases)
	func anUnconfirmedChangeIsReadAgainAtEveryRecover(_ kind: ChangeKind) async throws {
		let unconfirmed = try await Unconfirmed(kind)
		let rig = unconfirmed.rig
		let calendar = unconfirmed.calendar
		calendar.failReads()
		let desk = try rig.desk(calendar: calendar)
		let records = try await rig.records()

		await desk.recover()
		await desk.recover()

		#expect(calendar.calls == [.read, .read])
		#expect(try await rig.records() == records)
		try await unconfirmed.expectStillUnconfirmed()
		calendar.restoreReads()

		await desk.recover()

		#expect(calendar.calls == [.read, .read, .read])
		#expect(calendar.writes.isEmpty)
		let head = try #require(try await rig.head().1)
		#expect(head.stage == .waiting(.tryAgain(.settled)))
		#expect(head.work.finished.map(FinishedTag.init) == unconfirmed.settled(kind))
		#expect(try await rig.records() == records + 1)
	}

	@Test(arguments: ChangeKind.allCases)
	func checkAgainReadsTheChangeAndAFailedReadKeepsTheTokenUsable(_ kind: ChangeKind)
		async throws
	{
		let unconfirmed = try await Unconfirmed(kind)
		let rig = unconfirmed.rig
		let calendar = unconfirmed.calendar
		let desk = try rig.desk(calendar: calendar)
		let token = try await rig.token(on: desk)
		guard
			case .armed(.checkAgainOrCancel, token) = try await desk.snapshot(chat: .main)?.controls
		else {
			Issue.record("the unconfirmed change did not offer Check again")
			return
		}
		let records = try await rig.records()
		calendar.failReads()

		guard case .unconfirmed = await desk.decide(.checkAgain(token)) else {
			Issue.record("a failed Check again read did not keep the change unconfirmed")
			return
		}

		#expect(calendar.calls == [.read])
		#expect(try await rig.records() == records)
		try await unconfirmed.expectStillUnconfirmed()
		calendar.restoreReads()

		guard case .stopped = await desk.decide(.checkAgain(token)) else {
			Issue.record("the kept token did not read the change again")
			return
		}

		#expect(calendar.calls == [.read, .read])
		#expect(calendar.writes.isEmpty)
		let head = try #require(try await rig.head().1)
		#expect(head.stage == .waiting(.tryAgain(.settled)))
		#expect(head.work.finished.map(FinishedTag.init) == unconfirmed.settled(kind))
		#expect(try await rig.records() == records + 1)
	}

	@Test(arguments: DeadToken.allCases)
	func checkAgainWithAStaleTokenReadsNothing(_ dead: DeadToken) async throws {
		let unconfirmed = try await Unconfirmed(.add)
		let rig = unconfirmed.rig
		let calendar = unconfirmed.calendar
		let desk = try rig.desk(calendar: calendar)
		let token = try await rig.token(on: desk)
		let used: ReviewControlToken
		switch dead {
		case .renewed:
			#expect(await desk.decide(.showAgain(token.ref)) == .presentationRecorded)
			used = token
		case .consumed:
			_ = await desk.decide(.checkAgain(token))
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
		let calls = calendar.calls.count
		let records = try await rig.records()

		guard case .staleControl = await desk.decide(.checkAgain(used)) else {
			Issue.record("a stale Check again token was accepted")
			return
		}

		#expect(calendar.calls.count == calls)
		#expect(try await rig.records() == records)
	}

	@Test(arguments: OtherStage.allCases)
	func checkAgainInAnyOtherStageReadsNothingAndKeepsTheToken(_ stage: OtherStage) async throws {
		let rig = DeskRig()
		let review = try PreflightFixture.review([
			PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID()),
			rig.strength(on: "1998-09-12"),
		])
		let claimed = try review.claimed(
			Claim(id: ClaimID(ulid: reviewULID(804)), action: .approve))
		switch stage {
		case .approval:
			try await rig.save(review)
		case .tryAgain:
			let sending = try claimed.sending(
				at: rig.clock.now, seen: [review.work.remaining[0].id: EventID(rawValue: 204)])
			guard
				case .next(let stopped) = try sending.answered(
					.refused(.badRequest), at: rig.clock.now)
			else {
				throw UnexpectedReview(detail: "a refused answer did not stop the run")
			}
			try await rig.save(stopped)
		case .blocked:
			try await rig.save(try claimed.blocked(.coachOnly))
		}
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		let records = try await rig.records()

		#expect(await desk.decide(.checkAgain(token)) == .wrongAction)

		#expect(rig.calendar.calls.isEmpty)
		#expect(try await rig.records() == records)
		guard case .canceled = await desk.decide(.cancel(token)) else {
			Issue.record("the token stopped working after Check again in another stage")
			return
		}
	}
}
