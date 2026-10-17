import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ReviewExecutionTests {
	enum WriteKind: String, CaseIterable, CustomTestStringConvertible {
		case add, edit, delete

		var testDescription: String { rawValue }

		var position: Int {
			switch self {
			case .add: 1
			case .edit: 3
			case .delete: 4
			}
		}

		func action(on rig: DeskRig) throws -> ChangeAction {
			switch self {
			case .add:
				PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID())
			case .edit:
				try PreflightFixture.edit(try rig.event(201), PreflightFixture.patch(minutes: 75))
			case .delete:
				try PreflightFixture.delete(try rig.event(202))
			}
		}

		func land(_ write: CalendarWrite, on rig: DeskRig) async {
			switch self {
			case .add:
				_ = await rig.base.write(write)
			case .edit:
				rig.base.events[0].movingTime = 75 * 60
			case .delete:
				rig.base.events.remove(at: 1)
			}
		}

		var landedResult: ChangeResult {
			switch self {
			case .add: .seenOnCalendar(EventID(rawValue: 204))
			case .edit: .seenOnCalendar(EventID(rawValue: 201))
			case .delete: .noLongerOnCalendar
			}
		}
	}

	enum AfterLoss: String, CaseIterable, CustomTestStringConvertible {
		case landed, notLanded, readFailed

		var testDescription: String { rawValue }
	}

	enum RunEnding: String, CaseIterable, CustomTestStringConvertible {
		case completed, stopped, unconfirmed, storageFailure

		var testDescription: String { rawValue }

		var lease: LeaseEnding {
			self == .storageFailure ? .failed : .finished
		}
	}

	@Test func eachRequestLeavesOnlyAfterTheRecordHoldingItsAttemptIsTheHead() async throws {
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		let desk = try rig.desk()
		let seen = rig.watchHeads { if case .write = $0 { true } else { false } }

		_ = await desk.decide(.approve(try await rig.token(on: desk)))

		#expect(seen.all.map(\.sendingChange) == review.work.remaining.map(\.id))
	}

	@Test(arguments: WriteKind.allCases)
	func anAttemptThatIsNotSavedSendsNoRequest(_ kind: WriteKind) async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let rig = DeskRig(store: faults)
		let review = try rig.mixed()
		try await rig.save(review)
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		try faults.failAppend(ofKind: "workoutReview", skipping: kind.position)

		#expect(await desk.decide(.approve(token)) == .storageUnavailable)

		let sent = Array(review.work.remaining.prefix(kind.position - 1))
		#expect(rig.calendar.writes == sent.map(DeskRig.request))
		let head = try #require(try await rig.head().1)
		if let last = sent.last {
			#expect(head.sendingChange == last.id)
		} else {
			#expect(head.isClaimOnly)
		}
	}

	@Test func aRefusedThirdChangeStopsTheRunAndKeepsFinishedApartFromRemaining()
		async throws
	{
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		rig.calendar.answer { index, _ in index == 2 ? .httpStatus(400) : nil }
		let desk = try rig.desk()

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		#expect(rig.calendar.writes == review.work.remaining.prefix(3).map(DeskRig.request))
		guard case .stopped(let receipts, _) = outcome else {
			Issue.record("the refused change ended \(outcome)")
			return
		}
		#expect(
			receipts.map(\.progress) == [
				.saved(EventID(rawValue: 204)), .saved(EventID(rawValue: 205)), .refused,
			])
		let head = try #require(try await rig.head().1)
		let third = review.work.remaining[2]
		#expect(head.stage == .waiting(.tryAgain(.refused(third.id, .badRequest))))
		#expect(head.work.finished.map(\.change) == Array(review.work.remaining.prefix(2)))
		#expect(head.work.remaining == Array(review.work.remaining.suffix(2)))
	}

	@Test(arguments: WriteKind.allCases, AfterLoss.allCases)
	func aLostAnswerStopsTheRunAndIsSettledByOneImmediateRead(
		_ kind: WriteKind, _ loss: AfterLoss
	) async throws {
		let rig = DeskRig()
		let review = try PreflightFixture.review([
			try kind.action(on: rig), rig.strength(on: "1998-09-12"),
		])
		try await rig.save(review)
		rig.calendar.answer { [rig] index, write in
			guard index == 0 else { return nil }
			switch loss {
			case .landed: await kind.land(write, on: rig)
			case .notLanded: break
			case .readFailed: rig.calendar.failReads()
			}
			return .lost(.transport)
		}
		let desk = try rig.desk()

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		#expect(rig.calendar.writes.count == 1)
		let lost = try #require(review.work.remaining.first)
		let follower = Array(review.work.remaining.dropFirst())
		let head = try #require(try await rig.head().1)
		switch loss {
		case .landed:
			#expect(head.work.finished == [FinishedChange(change: lost, result: kind.landedResult)])
			#expect(head.work.remaining == follower)
			#expect(head.stage == .waiting(.tryAgain(.settled)))
		case .notLanded:
			#expect(head.work.finished.isEmpty)
			#expect(head.work.remaining == review.work.remaining)
			#expect(head.stage == .waiting(.approval(.interruptedBeforeWriting)))
		case .readFailed:
			#expect(head.work.remaining == follower)
			guard case .waiting(.unconfirmed(let attempt)) = head.stage,
				case .unconfirmed = outcome
			else {
				Issue.record("a failed read ended \(outcome) at \(head.stage)")
				return
			}
			#expect(attempt.change == lost)
		}
	}

	@Test(arguments: RunEnding.allCases)
	func theRunHoldsOneLeaseFromTheClaimUntilItEnds(_ ending: RunEnding) async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let rig = DeskRig(store: faults)
		try await rig.save(try rig.mixed())
		let host = rig.host
		let openDuringCalls = Mutex<[Bool]>([])
		rig.calendar.observe { _ in
			let open = host.leases.count == 1 && host.leases.first?.ending == nil
			openDuringCalls.withLock { $0.append(open) }
		}
		switch ending {
		case .completed:
			break
		case .stopped:
			rig.calendar.answer { index, _ in index == 1 ? .httpStatus(429) : nil }
		case .unconfirmed:
			rig.calendar.answer { index, _ in
				guard index == 1 else { return nil }
				rig.calendar.failReads()
				return .lost(.transport)
			}
		case .storageFailure:
			try faults.failAppend(ofKind: "workoutReview", skipping: 2)
		}
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		#expect(host.leases.isEmpty)

		_ = await desk.decide(.approve(token))

		#expect(host.leases.map(\.request) == [LeaseRequest(chat: .main, initiatedBy: .athlete)])
		#expect(host.leases.map(\.ending) == [ending.lease])
		#expect(host.leases.map(\.expiry) == [nil])
		let open = openDuringCalls.withLock { $0 }
		#expect(!open.isEmpty)
		#expect(open.allSatisfy { $0 })
	}

	@Test func anEndedLeaseLeavesTheChangeInFlightUnconfirmedForRecovery() async throws {
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		let host = rig.host
		rig.calendar.answer { index, _ in
			guard index == 1 else { return nil }
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

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		guard case .unconfirmed(let receipts, _) = outcome else {
			Issue.record("the ended lease gave \(outcome)")
			return
		}
		#expect(receipts.map(\.progress) == [.saved(EventID(rawValue: 204)), .mayHaveBeenSaved])
		#expect(rig.calendar.writes.count == 2)
		#expect(host.leases.map(\.ending) == [.interrupted(.systemExpired)])
		let head = try #require(try await rig.head().1)
		guard case .waiting(.unconfirmed(let attempt)) = head.stage else {
			Issue.record("the change in flight was saved as \(head.stage)")
			return
		}
		#expect(attempt.change == review.work.remaining[1])
		#expect(head.nextStep(.resume, summarySaved: false) == .settle(attempt))
	}
}
