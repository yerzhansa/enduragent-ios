import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct WorkoutReviewDefectTests {
	@Test func twoDesksApproveOnceRunOnce() async throws {
		let barrier = BarrierChainLog(InMemoryRecordLog())
		let rig = DeskRig(store: barrier)
		try await rig.save(try rig.mixed())
		let phone = try rig.desk()
		let pad = try rig.desk()
		let phoneToken = try await rig.token(on: phone)
		let padToken = try await rig.token(on: pad)
		barrier.arm(readers: 2)

		async let fromPhone = phone.decide(.approve(phoneToken))
		async let fromPad = pad.decide(.approve(padToken))
		let outcomes = await [fromPhone, fromPad]

		#expect(barrier.heldReads == 2)
		#expect(outcomes.filter { $0 == .staleControl(newer: nil) }.count == 1)
		#expect(outcomes.contains { if case .completed = $0 { true } else { false } })
		let chain = try await rig.chain()
		#expect(chain.filter(\.isClaimOnly).count == 1)
		#expect(chain.count == 7)
		#expect(rig.calendar.writes.count == 4)
	}

	@Test func changedTargetBeforeApprovalWritesNothing() async throws {
		let rig = DeskRig()
		try await rig.save(
			try PreflightFixture.review([
				PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID()),
				try PreflightFixture.edit(try rig.event(201), PreflightFixture.patch(minutes: 75)),
			]))
		rig.base.events[0].movingTime = 50 * 60
		let desk = try rig.desk()

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		guard case .refreshed = outcome else {
			Issue.record("the changed target gave \(outcome)")
			return
		}
		#expect(rig.calendar.writes.isEmpty)
		let head = try #require(try await rig.head().1)
		guard case .waiting(.approval(.refreshed(let differences))) = head.stage else {
			Issue.record("the changed target was saved as \(head.stage)")
			return
		}
		#expect(differences.map(\.fields) == [[.duration]])
	}

	@Test func unownedTargetWritesNothing() async throws {
		let rig = DeskRig()
		try await rig.save(
			try PreflightFixture.review([
				PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID()),
				try PreflightFixture.edit(try rig.event(201), PreflightFixture.patch(minutes: 75)),
			]))
		rig.base.events[0].tags = []
		rig.base.events[0].coachCreated = false
		let desk = try rig.desk()

		#expect(await desk.decide(.approve(try await rig.token(on: desk))) == .blocked(.coachOnly))

		#expect(rig.calendar.writes.isEmpty)
		let shown = try #require(try await desk.snapshot(chat: .main))
		#expect(await desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(.cancelOnly, let token) = try #require(try await desk.snapshot(chat: .main))
				.controls
		else {
			Issue.record("the blocked review did not offer Cancel alone")
			return
		}
		#expect(await desk.decide(.approve(token)) == .wrongAction)
		#expect(rig.calendar.writes.isEmpty)
	}
}
