import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewUpgradeTests {
	enum Missing: String, CaseIterable, CustomTestStringConvertible {
		case payload, identity

		var testDescription: String { rawValue }
	}

	enum Upgraded: String, CaseIterable, CustomTestStringConvertible {
		case edit, delete

		var testDescription: String { rawValue }

		var input: GatedToolInput {
			switch self {
			case .edit:
				.updateWorkout(
					UpdateWorkoutInput(
						eventId: EventID(rawValue: 201), date: nil, name: "Tempo",
						description: nil))
			case .delete: .deleteWorkout(eventId: EventID(rawValue: 202))
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

	static let strength = GatedToolInput.createStrengthWorkout(
		date: "1998-09-12", name: "Strength", description: "Squats and core")

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
				LegacyProposal(
					review: WorkoutReviewID(ulid: reviewULID(901)), nonce: Nonce(rawValue: UUID()),
					stamp: legacy.stamp(), identity: CalendarWriteID()),
				target: .create(date: "1998-09-12"), clearing: false)
		case .identity:
			try await legacy.sendUnknown(
				try await legacy.propose(Self.strength, identity: nil), target: nil)
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
			try await legacy.propose(upgraded.input, identity: CalendarWriteID()),
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

struct LegacyProposal {
	let review: WorkoutReviewID
	let nonce: Nonce
	let stamp: OperationStamp
	let identity: CalendarWriteID?
}

struct LegacyReviews {
	let rig: DeskRig

	func propose(
		_ input: GatedToolInput, identity: CalendarWriteID? = nil, in chat: ChatID = .main
	) async throws -> LegacyProposal {
		let stamp = stamp()
		let nonce = Nonce(rawValue: UUID())
		let saved = try await rig.ledger().commit(
			local: [
				.pendingProposal(
					ProposalBody(
						writeID: identity, chatId: chat, nonce: nonce, tool: Self.tool(of: input),
						toolInput: input, summary: "Legacy", description: "Legacy",
						expiresAt: rig.clock.now.addingTimeInterval(ProposalPolicy.ttlSeconds)))
			], stamp: stamp)
		let record = try #require(saved.first)
		return LegacyProposal(
			review: WorkoutReviewID(ulid: record.ulid), nonce: nonce, stamp: stamp,
			identity: identity)
	}

	func stamp() -> OperationStamp {
		testStamp(attempt: ULID.generate(at: rig.clock.now), account: PreflightFixture.account)
	}

	@discardableResult
	func sendUnknown(
		_ proposal: LegacyProposal, target: CalendarWriteTarget?, clearing: Bool = true
	) async throws -> LegacyProposal {
		var body = ReviewWriteBody(
			chatId: .main, review: proposal.review, writeID: proposal.identity, target: target,
			evidence: .notSent)
		let ledger = rig.ledger()
		_ = try await ledger.commit(synced: [.reviewWrite(body)], stamp: proposal.stamp)
		body.evidence = .unknown(.dispatched)
		_ = try await ledger.commit(synced: [.reviewWrite(body)], stamp: proposal.stamp)
		if clearing {
			_ = try await ledger.commit(
				local: [
					.proposalCleared(
						ProposalClearedBody(chatId: .main, nonce: proposal.nonce, reason: .executed)
					)
				], stamp: proposal.stamp)
		}
		return proposal
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

	private static func tool(of input: GatedToolInput) -> GatedToolName {
		switch input {
		case .createWorkout: .intervalsCreateWorkout
		case .createStrengthWorkout: .intervalsCreateStrengthWorkout
		case .updateWorkout: .intervalsUpdateWorkout
		case .deleteWorkout: .intervalsDeleteWorkout
		case .planSave: .planSave
		}
	}
}
