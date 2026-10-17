import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct FinishedTag: Equatable {
	enum Result: Equatable {
		case saved(Int)
		case seen(Int)
		case gone
	}

	let change: ChangeID
	let result: Result

	init(_ change: ReviewChange, _ result: Result) {
		self.change = change.id
		self.result = result
	}

	init(_ finished: FinishedChange) {
		change = finished.change.id
		result =
			switch finished.result {
			case .saved(let receipt): .saved(receipt.event.rawValue)
			case .seenOnCalendar(let event): .seen(event.rawValue)
			case .noLongerOnCalendar: .gone
			}
	}
}

struct Recovered {
	let stage: Stage
	let finished: [FinishedTag]
	let remaining: [ReviewChange]
	let reads: Int
	let appended: Int
	let published: [ReviewOutcomeBody.Ending]
	let requests: Int
	let reached: Int
}

@Suite struct ReviewRecoveryTests {
	@Test(arguments: CrashRow.all)
	func aDriveStoppedForGoodAtEachPointIsSettledByTheNextRecover(_ row: CrashRow) async throws {
		let rig = DeskRig()
		let review = try PreflightFixture.review(try row.actions(on: rig))
		let changes = review.work.remaining
		switch row.point {
		case .retriedClaimDuringPreflight: try await rig.save(try rig.retriedClaim(over: review))
		default: try await rig.save(review)
		}
		switch row.point {
		case .refreshedVerdictUnsaved: rig.base.events[0].movingTime = 50 * 60
		case .blockedVerdictUnsaved:
			rig.base.events[0].tags = []
			rig.base.events[0].coachCreated = false
		default: break
		}
		let crash = try await rig.stop(row)
		if row.point == .movedAddLandedUnanswered {
			let moved = try #require(
				rig.base.events.firstIndex { $0.externalId != nil && $0.id.rawValue == 205 })
			rig.base.events[moved].startDateLocal = "1998-10-09T00:00:00"
		}
		let recovering = ScriptedCalendar(rig.base)
		let desk = try rig.desk(calendar: recovering)
		let expected = try expectation(for: row, changes, crash)
		switch try await rig.head().1?.stage {
		case .completed?, .canceled?:
			guard !expected.published.isEmpty else { break }
			let shown = try #require(try await desk.snapshot(chat: .main))
			#expect(shown.authority == .readOnly)
			#expect(shown.controls == .none)
		case .waiting?, .running?, nil:
			break
		}
		let outcomesBefore = try await rig.outcomes().count

		await desk.recover()

		#expect(crash.calendar.calls.count == crash.calls)
		#expect(recovering.writes.isEmpty)
		#expect(recovering.calls == Array(repeating: .read, count: expected.reads))
		let head = try #require(try await rig.head().1)
		#expect(head.stage == expected.stage)
		#expect(head.work.finished.map(FinishedTag.init) == expected.finished)
		#expect(head.work.remaining == expected.remaining)
		let published = try await rig.outcomes()
		#expect(published.dropFirst(outcomesBefore).map(\.ending) == expected.published)
		#expect(
			try await rig.records() == crash.records + expected.appended + expected.published.count)
		#expect(
			[crash.calendar, recovering].map(\.writes.count).reduce(0, +) + setupWrites(row)
				== expected.requests)
		#expect(rig.base.calls.filter(\.isCalendarWrite).count == expected.reached)
		if !expected.published.isEmpty {
			#expect(try await desk.snapshot(chat: .main) == nil)
		}
		try await followUp(row, on: desk, rig, changes)
		#expect(rig.base.calls.filter(\.isCalendarWrite).count == expected.reached)
	}

	private func setupWrites(_ row: CrashRow) -> Int {
		switch row.point {
		case .checkAgainUnrecorded, .cancelOfUnconfirmedUnsaved, .canceledUnconfirmedUnpublished: 2
		default: 0
		}
	}

	private func expectation(for row: CrashRow, _ changes: [ReviewChange], _ crash: Crash) throws
		-> Recovered
	{
		let first = changes[0]
		let saved = FinishedTag(first, .saved(204))
		guard let kind = row.kind else {
			switch row.point {
			case .tap, .cancelUnsaved:
				return Recovered(
					stage: .waiting(.approval(.prepared)), finished: [], remaining: changes,
					reads: 0, appended: 0, published: [], requests: 0, reached: 0)
			case .retriedClaimDuringPreflight:
				return Recovered(
					stage: .waiting(.tryAgain(.interrupted)),
					finished: [FinishedTag(first, .seen(204))],
					remaining: Array(changes.dropFirst()), reads: 0, appended: 1, published: [],
					requests: 0, reached: 0)
			case .completedUnpublished, .published:
				return Recovered(
					stage: .completed, finished: [saved, FinishedTag(changes[1], .saved(205))],
					remaining: [], reads: 0, appended: 0,
					published: row.point == .published ? [] : [.completed], requests: 2,
					reached: 2)
			default:
				return Recovered(
					stage: .waiting(.approval(.interruptedBeforeWriting)), finished: [],
					remaining: changes, reads: 0, appended: 1, published: [], requests: 0,
					reached: 0)
			}
		}
		if row.point == .firstAttemptSavedRequestHeld {
			return Recovered(
				stage: .waiting(.approval(.interruptedBeforeWriting)), finished: [],
				remaining: changes, reads: 1, appended: 1, published: [], requests: 1, reached: 0)
		}
		let changed = changes[1]
		let landed: FinishedTag.Result =
			switch kind {
			case .add: .seen(205)
			case .edit: .seen(201)
			case .delete: .gone
			}
		let settled = [saved, FinishedTag(changed, landed)]
		switch row.point {
		case .attemptSavedRequestHeld, .refusalUnrecorded:
			return Recovered(
				stage: .waiting(.tryAgain(.notSaved(changed.id))), finished: [saved],
				remaining: Array(changes.dropFirst()), reads: 1, appended: 1, published: [],
				requests: 2, reached: 1)
		case .lastRequestLandedUnanswered:
			return Recovered(
				stage: .completed, finished: settled, remaining: [], reads: 1, appended: 1,
				published: [.completed], requests: 2, reached: 2)
		case .canceledUnconfirmedUnpublished:
			return Recovered(
				stage: .canceled(
					Cancellation(
						givenUp: [changes[2]], unconfirmed: try #require(crash.unconfirmed))),
				finished: [saved], remaining: [], reads: 0, appended: 0, published: [.canceled],
				requests: 2, reached: 2)
		default:
			return Recovered(
				stage: .waiting(.tryAgain(.settled)), finished: settled, remaining: [changes[2]],
				reads: 1, appended: 1, published: [], requests: 2, reached: 2)
		}
	}

	private func followUp(
		_ row: CrashRow, on desk: WorkoutReviewDesk, _ rig: DeskRig, _ changes: [ReviewChange]
	) async throws {
		switch row.point {
		case .refreshedVerdictUnsaved:
			guard case .refreshed = await desk.decide(.approve(try await rig.token(on: desk))),
				case .waiting(.approval(.refreshed(let differences))) = try await rig.head().1?
					.stage
			else {
				Issue.record("approving again did not find the same changed target")
				return
			}
			#expect(differences.map(\.fields) == [[.duration]])
			#expect(differences.map(\.change) == [changes[1].id])
		case .blockedVerdictUnsaved:
			#expect(
				await desk.decide(.approve(try await rig.token(on: desk))) == .blocked(.coachOnly))
			#expect(try await rig.head().1?.stage == .waiting(.blocked(.coachOnly)))
		case .cancelUnsaved, .cancelOfUnconfirmedUnsaved:
			guard case .canceled = await desk.decide(.cancel(try await rig.token(on: desk))) else {
				Issue.record("Cancel did not work again after the unsaved cancel")
				return
			}
			guard case .canceled = try await rig.head().1?.stage else {
				Issue.record("the second cancel was not saved")
				return
			}
		default:
			return
		}
	}
}

extension FakeIntervalsCall {
	var isCalendarWrite: Bool {
		switch self {
		case .createEvent, .updateEvent, .deleteEvent: true
		case .profile, .activities, .wellness, .activity, .streams, .events: false
		}
	}
}
