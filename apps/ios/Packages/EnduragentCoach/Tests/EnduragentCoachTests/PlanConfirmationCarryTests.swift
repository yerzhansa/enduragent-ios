import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension PlanConfirmationTests {
	@Test func aWaitingCardIsCarriedArmedToTheTopAndReadsCanceledThereUntilTheNextReset()
		async throws
	{
		let coach = await turns.coach()
		let token = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)

		_ = await coach.resetAndSettle(in: .main)

		let carried = try await turns.cards(on: coach)
		#expect(carried.map(\.placement) == [.preparedEarlier])
		#expect(carried.map(\.state) == [.waiting(.armed(token))])
		#expect(await coach.decide(.cancel(token), in: .main) == .canceled)
		#expect(try await turns.cards(on: coach).map(\.state) == [.canceled])
		#expect(try await turns.cards(on: coach).map(\.placement) == [.preparedEarlier])

		_ = await coach.resetAndSettle(in: .main)

		#expect(try await turns.cards(on: coach).isEmpty)
		#expect(try await turns.savedPlanRows() == 0)
	}

	@Test func aCarriedCardWhoseTenMinutesEndReadsExpiredAtTheTopUntilTheNextReset()
		async throws
	{
		let coach = await turns.coach()
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		try await turns.clock.waitUntilHeld(.seconds(600))
		_ = await coach.resetAndSettle(in: .main)

		turns.clock.advance(by: .seconds(600))

		let expired = try await turns.waitForCards(on: coach) { $0.map(\.state) == [.expired] }
		#expect(expired?.map(\.placement) == [.preparedEarlier])
		_ = await coach.resetAndSettle(in: .main)
		#expect(try await turns.cards(on: coach).isEmpty)
	}

	enum Before: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case saved
		case canceled
		case expired

		var testDescription: String { rawValue }
	}

	@Test(arguments: Before.allCases)
	func noCardIsCarriedForAConfirmationThatEndedBeforeTheReset(_ before: Before) async throws {
		let coach = await turns.coach()
		let token = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		switch before {
		case .saved: #expect(await coach.decide(.save(token), in: .main) == .saved)
		case .canceled: #expect(await coach.decide(.cancel(token), in: .main) == .canceled)
		case .expired:
			try await turns.clock.waitUntilHeld(.seconds(600))
			turns.clock.advance(by: .seconds(601))
		}

		_ = await coach.resetAndSettle(in: .main)

		#expect(try await turns.cards(on: coach).isEmpty)
	}

	@Test func onlyTheNewestConfirmationIsCarried() async throws {
		let coach = await turns.coach()
		_ = try await turns.reply(after: [[turns.save(PlanTurns.threshold)]], on: coach)
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		let newest = try #require(try await turns.cards(on: coach).last?.id)

		_ = await coach.resetAndSettle(in: .main)

		let carried = try await turns.cards(on: coach)
		#expect(carried.map(\.id) == [newest])
		#expect(carried.map(\.state) == [.waiting(.unarmed)])
	}

	@Test(arguments: [0, 1])
	func aConfirmationWhoseTenMinutesEndAtTheResetIsNotCarriedAndOneASecondYoungerIs(
		offset: Int
	) async throws {
		let coach = await turns.coach()
		turns.clock.advance(by: .seconds(offset))
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		turns.clock.advance(by: .seconds(600 - offset))

		_ = await coach.resetAndSettle(in: .main)

		let carried = try await turns.cards(on: coach)
		#expect(carried.map(\.placement) == (offset == 0 ? [] : [.preparedEarlier]))
	}

	@Test func aConfirmationIsCarriedUntilTheTenMinutesFromItsPreparedStepsHLCEnd()
		async throws
	{
		let log = InterleavingChainLog(turns.store)
		let clock = turns.clock
		let store = turns.store
		log.interleave(on: .planChain(of: .main), times: 1) {
			clock.advance(by: .seconds(2))
			try await PlanTurns.moveHead(of: store, foreign: 7)
		}
		let coach = await turns.coach(over: log)
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		let prepared = try #require(try await turns.prepared(in: turns.store).first)
		let step = try #require(
			try await turns.steps(in: turns.store).first { record in
				if case .prepared = record.body.step { return true }
				return false
			})
		clock.advance(by: .seconds(599))
		#expect(prepared.expiresAt < clock.now)
		#expect(clock.now < step.hlc.wallTime.addingTimeInterval(600))

		_ = await coach.resetAndSettle(in: .main)

		let carried = try await turns.cards(on: coach)
		#expect(carried.map(\.placement) == [.preparedEarlier])
		#expect(carried.map(\.state) == [.expired])
	}

	@Test func saveAndCancelCallNoCalendarAndApprovingAWorkoutReviewSavesNoPlan() async throws {
		let coach = await turns.coach()
		let saved = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		let beforeSave = turns.intervals.calls.count
		#expect(await coach.decide(.save(saved), in: .main) == .saved)
		#expect(turns.intervals.calls.count == beforeSave)
		let canceled = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		let beforeCancel = turns.intervals.calls.count
		#expect(await coach.decide(.cancel(canceled), in: .main) == .canceled)
		#expect(turns.intervals.calls.count == beforeCancel)

		try await approveAWorkoutReview(on: coach)

		#expect(turns.calendarWrites().count == 1)
		#expect(try await turns.savedPlanRows() == 1)
		#expect(try await turns.planLoad(on: coach) == PlanTurns.threshold)
	}

	@Test func aWorkoutReviewWaitingPastTheConfirmationsTenMinutesStaysApprovable() async throws {
		let coach = await turns.coach()
		_ = try await turns.reply(
			after: [
				[turns.prepareWorkouts()], [turns.save(PlanTurns.baseBuild)],
			], on: coach)
		try await turns.clock.waitUntilHeld(.seconds(600))

		turns.clock.advance(by: .seconds(660))

		#expect(try await turns.waitForCards(on: coach) { $0.map(\.state) == [.expired] } != nil)
		try await approveAWorkoutReview(on: coach, preparing: false)
		#expect(turns.calendarWrites().count == 1)
		#expect(try await turns.savedPlanRows() == 0)
	}

	@Test func draftsAndASampleWeekLeaveTheSavedPlanAndTheCalendarAlone() async throws {
		try await turns.store.append(
			[
				storedRecord(
					device: turns.store.deviceId, wall: 1, ulid: fixedUlid(1),
					body: try SavedPlanRows.body(PlanTurns.threshold))
			], locality: .synced)
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		let coach = await turns.coach(secrets: secrets)
		let profile =
			#"{"experienceLevel":"intermediate","ftpWatts":250,"volumeTier":"medium","scheduleType":"flexible","goalType":"race","raceType":"gran_fondo","raceDate":"1998-08-09"}"#
		let revised = profile.replacingOccurrences(of: #""medium""#, with: #""high""#)

		let turn = try await turns.reply(
			after: [
				[.toolCall(name: "build_plan_skeleton", arguments: profile)],
				[.toolCall(name: "build_plan_skeleton", arguments: revised)],
				[
					.toolCall(
						name: "get_sample_week",
						arguments: #"{"volumeTier":"high","scheduleType":"flexible"}"#)
				],
			], on: coach, asking: "Draft me a plan")

		#expect(try turns.toolData().count == 3)
		#expect(try await turns.settled(turn).count == 1)
		#expect(try await turns.steps(in: turns.store).isEmpty)
		#expect(try await turns.cards(on: coach).isEmpty)
		#expect(try await turns.savedPlanRows() == 1)
		#expect(try await turns.planLoad(on: coach) == PlanTurns.threshold)
		#expect(turns.intervals.calls.isEmpty)
	}

	private func approveAWorkoutReview(on coach: Coach, preparing: Bool = true) async throws {
		if preparing {
			_ = try await turns.reply(after: [[turns.prepareWorkouts()]], on: coach)
		}
		let review = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let armed = try #require(try await coach.desk.snapshot(chat: .main))
		guard case .armed(.approveOrCancel, let token) = armed.controls else {
			Issue.record("the workout review offers \(armed.controls)")
			return
		}
		guard case .completed = await coach.decide(.approve(token), in: .main) else {
			Issue.record("the workout review did not complete")
			return
		}
	}
}

extension PlanTurns {
	func prepareWorkouts() -> ScriptedEvent {
		.toolCall(
			name: "prepare_workout_changes",
			arguments: WorkoutReviewFixture.strengthSessions(1, today: "1998-06-13"))
	}
}
