import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

typealias ChangeKind = ReviewExecutionTests.WriteKind

final class HeldCall: Sendable {
	private struct State {
		var reached = false
		var released = false
	}

	private let state = Mutex(State())

	var reached: Bool { state.withLock { $0.reached } }

	func release() {
		state.withLock { $0.released = true }
	}

	func hold() async {
		state.withLock { $0.reached = true }
		do {
			try await waitUntil { Task.isCancelled || self.state.withLock { $0.released } }
		} catch is CancellationError {
			return
		} catch {
			Issue.record(error, "a held calendar call stopped waiting")
		}
	}

	func waitUntilReached() async throws {
		try await waitUntil { self.reached }
	}
}

enum CrashPoint: String, CaseIterable, Sendable {
	case tap
	case claimDuringPreflight
	case retriedClaimDuringPreflight
	case refreshedVerdictUnsaved
	case blockedVerdictUnsaved
	case firstAttemptSavedRequestHeld
	case attemptSavedRequestHeld
	case requestLandedUnanswered
	case lastRequestLandedUnanswered
	case movedAddLandedUnanswered
	case answerUnrecorded
	case refusalUnrecorded
	case settleReadHeld
	case checkAgainUnrecorded
	case cancelUnsaved
	case cancelOfUnconfirmedUnsaved
	case completedUnpublished
	case canceledUnconfirmedUnpublished
	case published

	var kinds: [ChangeKind?] {
		switch self {
		case .tap, .claimDuringPreflight, .retriedClaimDuringPreflight, .refreshedVerdictUnsaved,
			.blockedVerdictUnsaved, .cancelUnsaved, .completedUnpublished, .published:
			[nil]
		case .movedAddLandedUnanswered:
			[.add]
		case .firstAttemptSavedRequestHeld, .attemptSavedRequestHeld, .requestLandedUnanswered,
			.lastRequestLandedUnanswered, .answerUnrecorded, .refusalUnrecorded, .settleReadHeld,
			.checkAgainUnrecorded, .cancelOfUnconfirmedUnsaved, .canceledUnconfirmedUnpublished:
			ChangeKind.allCases
		}
	}
}

struct CrashRow: Sendable, CustomTestStringConvertible {
	let point: CrashPoint
	let kind: ChangeKind?

	static let all = CrashPoint.allCases.flatMap { point in
		point.kinds.map { CrashRow(point: point, kind: $0) }
	}

	var testDescription: String {
		kind.map { "\(point.rawValue) \($0.rawValue)" } ?? point.rawValue
	}

	func actions(on rig: DeskRig) throws -> [ChangeAction] {
		let before = rig.strength(on: "1998-09-12")
		let after = rig.strength(on: "1998-09-14")
		guard let kind else {
			switch point {
			case .refreshedVerdictUnsaved, .blockedVerdictUnsaved:
				return [
					before,
					try PreflightFixture.edit(
						try rig.event(201), PreflightFixture.patch(minutes: 75)),
				]
			default:
				return [before, after]
			}
		}
		let changed = try kind.action(on: rig)
		switch point {
		case .firstAttemptSavedRequestHeld: return [changed, after]
		case .lastRequestLandedUnanswered: return [before, changed]
		default: return [before, changed, after]
		}
	}
}

struct Crash {
	let calendar: ScriptedCalendar
	let calls: Int
	let records: Int
	let unconfirmed: SendAttempt?
}

final class Flag: Sendable {
	private let state = Mutex(false)

	var raised: Bool { state.withLock { $0 } }

	func raise() {
		state.withLock { $0 = true }
	}
}

extension DeskRig {
	func records() async throws -> Int {
		try await chain().count + outcomes().count
	}

	func retriedClaim(over review: WorkoutReview) throws -> WorkoutReview {
		let first = try #require(review.work.remaining.first)
		let sending = try review.claimed(
			Claim(id: ClaimID(ulid: reviewULID(801)), action: .approve)
		)
		.sending(at: clock.now, seen: [first.id: EventID(rawValue: 204)])
		guard case .next(let stopped) = try sending.answered(.refused(.badRequest), at: clock.now)
		else {
			throw UnexpectedReview(detail: "a refused answer did not stop the run")
		}
		return try stopped.claimed(Claim(id: ClaimID(ulid: reviewULID(802)), action: .tryAgain))
	}

	func leaveUnconfirmed(at index: Int) async throws {
		let setup = ScriptedCalendar(base)
		setup.answer { [self] position, write in
			let answer = await keep(write)
			guard position == index else { return answer }
			setup.failReads()
			return .lost(.transport)
		}
		let desk = try desk(calendar: setup)
		guard case .unconfirmed = await desk.decide(.approve(try await token(on: desk))) else {
			throw UnexpectedReview(detail: "the setup run did not leave an unconfirmed change")
		}
	}

	func stop(_ row: CrashRow) async throws -> Crash {
		let dying = FaultInjectingRecordLog(wrapping: store)
		let old = ScriptedCalendar(base)
		let desk = try desk(over: dying, calendar: old)
		let index = row.point == .firstAttemptSavedRequestHeld ? 0 : 1
		switch row.point {
		case .retriedClaimDuringPreflight:
			break
		case .tap, .cancelUnsaved:
			let token = try await token(on: desk)
			dying.refuseEveryAppend(after: 0)
			let decision: ReviewDecision = row.point == .tap ? .approve(token) : .cancel(token)
			#expect(await desk.decide(decision) == .storageUnavailable)
		case .claimDuringPreflight, .refreshedVerdictUnsaved, .blockedVerdictUnsaved:
			try await approve(on: desk, refusingAfter: 1, dying)
		case .answerUnrecorded:
			old.answer { [self] _, write in await keep(write) }
			try await approve(on: desk, refusingAfter: 3, dying)
		case .refusalUnrecorded:
			old.answer { [self] position, write in
				position == index ? .httpStatus(400) : await keep(write)
			}
			try await approve(on: desk, refusingAfter: 3, dying)
		case .completedUnpublished:
			old.answer { [self] _, write in await keep(write) }
			try await approve(on: desk, refusingAfter: 4, dying)
		case .published:
			old.answer { [self] _, write in await keep(write) }
			guard case .completed = await desk.decide(.approve(try await token(on: desk))) else {
				throw UnexpectedReview(detail: "the run to publish did not complete")
			}
		case .firstAttemptSavedRequestHeld, .attemptSavedRequestHeld:
			let held = HeldCall()
			old.answer { [self] position, write in
				guard position == index else { return await keep(write) }
				await held.hold()
				return .lost(.canceled)
			}
			return try await interrupt(desk, at: held, dying, old)
		case .requestLandedUnanswered, .lastRequestLandedUnanswered, .movedAddLandedUnanswered:
			let held = HeldCall()
			old.answer { [self] position, write in
				let answer = await keep(write)
				guard position == index else { return answer }
				await held.hold()
				return .lost(.canceled)
			}
			return try await interrupt(desk, at: held, dying, old)
		case .settleReadHeld:
			let held = HeldCall()
			let lost = Flag()
			old.answer { [self] position, write in
				let answer = await keep(write)
				guard position == index else { return answer }
				lost.raise()
				return .lost(.transport)
			}
			old.observe { touch in
				guard touch == .read, lost.raised else { return }
				await held.hold()
			}
			return try await interrupt(desk, at: held, dying, old)
		case .checkAgainUnrecorded, .cancelOfUnconfirmedUnsaved, .canceledUnconfirmedUnpublished:
			return try await stopAfterUnconfirmed(row.point, on: desk, dying, old)
		}
		return Crash(
			calendar: old, calls: old.calls.count, records: try await records(), unconfirmed: nil)
	}

	private func approve(
		on desk: WorkoutReviewDesk, refusingAfter appends: Int, _ dying: FaultInjectingRecordLog
	) async throws {
		let token = try await token(on: desk)
		dying.refuseEveryAppend(after: appends)
		#expect(await desk.decide(.approve(token)) == .storageUnavailable)
	}

	private func interrupt(
		_ desk: WorkoutReviewDesk, at held: HeldCall, _ dying: FaultInjectingRecordLog,
		_ old: ScriptedCalendar
	) async throws -> Crash {
		let token = try await token(on: desk)
		let run = Task { await desk.decide(.approve(token)) }
		try await held.waitUntilReached()
		let crash = Crash(
			calendar: old, calls: old.calls.count, records: try await records(), unconfirmed: nil)
		dying.refuseEveryAppend(after: 0)
		old.failReads()
		await host.expire(.systemExpired)
		#expect(await run.value == .storageUnavailable)
		return crash
	}

	private func stopAfterUnconfirmed(
		_ point: CrashPoint, on desk: WorkoutReviewDesk, _ dying: FaultInjectingRecordLog,
		_ old: ScriptedCalendar
	) async throws -> Crash {
		try await leaveUnconfirmed(at: 1)
		guard case .waiting(.unconfirmed(let attempt)) = try await head().1?.stage else {
			throw UnexpectedReview(detail: "no unconfirmed change was saved")
		}
		let token = try await token(on: desk)
		switch point {
		case .checkAgainUnrecorded:
			dying.refuseEveryAppend(after: 0)
			#expect(await desk.decide(.checkAgain(token)) == .storageUnavailable)
		case .cancelOfUnconfirmedUnsaved:
			dying.refuseEveryAppend(after: 0)
			#expect(await desk.decide(.cancel(token)) == .storageUnavailable)
		default:
			dying.refuseEveryAppend(after: 1)
			#expect(await desk.decide(.cancel(token)) == .storageUnavailable)
		}
		return Crash(
			calendar: old, calls: old.calls.count, records: try await records(),
			unconfirmed: attempt)
	}
}
