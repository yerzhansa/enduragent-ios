import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewUpgradeTests {
	enum Missing: String, CaseIterable, CustomTestStringConvertible {
		case payload, identity, steps

		var testDescription: String { rawValue }
	}

	enum Upgraded: String, CaseIterable, CustomTestStringConvertible {
		case edit, delete

		var testDescription: String { rawValue }

		var change: LegacyCalendarChange {
			switch self {
			case .edit:
				.edit(
					EventID(rawValue: 201),
					WorkoutPatch(
						date: nil, name: "Tempo", durationSeconds: nil, description: nil,
						trainingLoad: nil, workoutDocument: nil, authoredSteps: nil))
			case .delete: .delete(EventID(rawValue: 202))
			}
		}

		var target: CalendarWriteTarget {
			switch self {
			case .edit: .update(eventID: 201, date: "1998-09-10")
			case .delete: .delete(eventID: 202, date: "1998-09-11")
			}
		}

		var reviewed: ReviewedTarget {
			switch self {
			case .edit: .upgradedWithoutSnapshot(EventID(rawValue: 201), "1998-09-10")
			case .delete: .upgradedWithoutSnapshot(EventID(rawValue: 202), "1998-09-11")
			}
		}
	}

	static let strength = LegacyCalendarChange.add(
		CalendarPayload(
			date: "1998-09-12", type: .weightTraining, name: "Strength",
			description: "Squats and core", movingTime: nil, trainingLoad: nil,
			authoredSteps: nil),
		ride: nil)

	static let rideWithUnreadableSteps = LegacyCalendarChange.add(
		CalendarPayload(
			date: "1998-09-12", type: .ride, name: "Tempo", description: "- 10m 55%",
			movingTime: nil, trainingLoad: nil, authoredSteps: nil),
		ride: IntervalsWorkoutInput(
			name: "Tempo",
			steps: [
				.simple(
					SimpleStep(
						type: .set, duration: DurationInput(value: 10, unit: .minutes),
						power: PowerTarget(kind: .percentFtp, value: 55, low: nil, high: nil),
						cadence: nil, label: nil))
			]))

	@Test func aFailedSecondUpgradeAppendLeavesTheRestForTheNextRecover() async throws {
		let rig = DeskRig()
		let legacy = LegacyReviews(rig: rig)
		let first = try await legacy.propose(Self.strength, in: "a")
		let second = try await legacy.propose(Self.strength, in: "b")
		let sent = try await legacy.sendUnknown(
			try await legacy.propose(Self.strength, identity: CalendarWriteID()),
			target: .create(date: "1998-09-12"))
		rig.calendar.failReads()
		let dying = FaultInjectingRecordLog(wrapping: rig.store)
		dying.refuseEveryAppend(after: 1)

		await (try rig.desk(over: dying)).recover()

		#expect(try await legacy.closed() == [first.review])
		#expect(try await legacy.reviewed().isEmpty)

		let desk = try rig.desk()
		await desk.recover()
		await desk.recover()

		#expect(try await legacy.closed() == [first.review, second.review])
		#expect(try await legacy.reviewed() == [sent.review])
		guard case .waiting(.unconfirmed) = try await rig.head().1?.stage else {
			Issue.record("the unknown write was not upgraded to an unconfirmed change")
			return
		}
		#expect(rig.calendar.writes.isEmpty)
	}

	@Test(arguments: Missing.allCases)
	func anUnknownWriteWithoutItsPayloadHereOrItsIdentityGetsNoReview(_ missing: Missing)
		async throws
	{
		let rig = DeskRig()
		let legacy = LegacyReviews(rig: rig)
		switch missing {
		case .payload:
			try await legacy.sendUnknown(
				SeededProposal(
					review: WorkoutReviewID(ulid: reviewULID(901)), nonce: Nonce(rawValue: UUID()),
					stamp: legacy.stamp(), identity: CalendarWriteID()),
				target: .create(date: "1998-09-12"), clearing: false)
		case .identity:
			try await legacy.sendUnknown(
				try await legacy.propose(Self.strength, identity: nil), target: nil)
		case .steps:
			try await legacy.sendUnknown(
				try await legacy.propose(Self.rideWithUnreadableSteps, identity: CalendarWriteID()),
				target: .create(date: "1998-09-12"))
		}

		await (try rig.desk()).recover()
		await (try rig.desk()).recover()

		#expect(try await legacy.reviewed().isEmpty)
		#expect(try await legacy.closed().isEmpty)
		#expect(rig.calendar.calls.isEmpty)
	}

	@Test(arguments: Upgraded.allCases)
	func anUpgradedEditOrDeleteThatDidNotLandBlocksWithReviewedBeforeUpgrade(
		_ upgraded: Upgraded
	) async throws {
		let rig = DeskRig()
		let legacy = LegacyReviews(rig: rig)
		let sent = try await legacy.sendUnknown(
			try await legacy.propose(upgraded.change, identity: CalendarWriteID()),
			target: upgraded.target)
		let desk = try rig.desk()

		await desk.recover()

		let head = try #require(try await rig.head().1)
		#expect(head.id == sent.review)
		#expect(head.stage == .waiting(.blocked(.reviewedBeforeUpgrade)))
		#expect(head.work.remaining.map(\.action.target) == [upgraded.reviewed])
		#expect(rig.calendar.calls == [.read])
		let token = try await rig.token(on: desk)
		guard
			case .armed(.cancelOnly, _) = try #require(try await desk.snapshot(chat: .main))
				.controls
		else {
			Issue.record("the blocked upgraded change offered more than Cancel")
			return
		}

		#expect(await desk.decide(.approve(token)) == .wrongAction)
		#expect(await desk.decide(.tryAgain(token)) == .wrongAction)

		#expect(rig.calendar.writes.isEmpty)
		#expect(try await rig.head().1 == head)
	}
}

struct SeededProposal {
	let review: WorkoutReviewID
	let nonce: Nonce
	let stamp: OperationStamp
	let identity: CalendarWriteID?
}

struct LegacyReviews {
	let rig: DeskRig

	func propose(
		_ change: LegacyCalendarChange, identity: CalendarWriteID? = nil, in chat: ChatID = .main
	) async throws -> SeededProposal {
		let stamp = stamp()
		let nonce = Nonce(rawValue: UUID())
		let record = try await seed(
			.pendingProposal(
				LegacyProposalBody(
					chatId: chat, nonce: nonce, writeID: identity, change: change,
					expiresAt: rig.clock.now.addingTimeInterval(600))),
			stamp: stamp)
		return SeededProposal(
			review: WorkoutReviewID(ulid: record.ulid), nonce: nonce, stamp: stamp,
			identity: identity)
	}

	func stamp() -> OperationStamp {
		testStamp(attempt: ULID.generate(at: rig.clock.now), account: PreflightFixture.account)
	}

	@discardableResult
	func sendUnknown(
		_ proposal: SeededProposal, target: CalendarWriteTarget?, clearing: Bool = true
	) async throws -> SeededProposal {
		var body = ReviewWriteBody(
			chatId: .main, review: proposal.review, writeID: proposal.identity, target: target,
			evidence: .notSent)
		try await seed(.reviewWrite(body), stamp: proposal.stamp)
		body.evidence = .unknown(.dispatched)
		try await seed(.reviewWrite(body), stamp: proposal.stamp)
		if clearing {
			try await seed(
				.proposalCleared(chatId: .main, nonce: proposal.nonce), stamp: proposal.stamp)
		}
		return proposal
	}

	@discardableResult
	private func seed(_ body: LegacyRecordBody, stamp: OperationStamp) async throws
		-> AthleteRecord
	{
		let record = await rig.ledger().prepare(.legacy(body), stamp: stamp)
		try await rig.store.append([record], locality: record.locality)
		return record
	}

	func closed() async throws -> [WorkoutReviewID] {
		try await rig.store.fetch(RecordQuery(scope: .synced([.reviewOutcome]))).records
			.compactMap { record in
				guard case .synced(.reviewOutcome(let body)) = record.body,
					body.ending == .closedAtUpgrade
				else { return nil }
				return body.review
			}
	}

	func reviewed() async throws -> [WorkoutReviewID] {
		try await rig.store.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]))).records
			.compactMap { record in
				guard case .deviceLocal(.workoutReview(let body)) = record.body else { return nil }
				return body.review.id
			}
	}
}
