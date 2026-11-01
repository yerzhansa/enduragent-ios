import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(1))) struct PlanRecoveryTests {
		let turns = PlanTurns()

		@Test(arguments: [5, 11])
		func aWaitingConfirmationSurvivesTheAppBeingEndedUntilItsTenMinutesEnd(minutes: Int)
			async throws
		{
			let rig = try PlanCrashRig()
			let crash = try await rig.stop(.s1)
			rig.clock.advance(by: .seconds(minutes * 60))
			let relaunch = try await rig.relaunch()
			await relaunch.coach.lifecycle(.becameActive)

			let cards = try await relaunch.turns.cards(on: relaunch.coach)

			guard minutes < 10 else {
				#expect(cards.map(\.state) == [.expired])
				let stale = try #require(crash.token)
				#expect(await relaunch.coach.decide(.save(stale), in: .main) == .notSaved(.expired))
				#expect(try await relaunch.turns.steps(in: relaunch.log).count == 1)
				#expect(try await SavedPlanRows.stored(in: relaunch.log).isEmpty)
				return
			}
			#expect(cards.map(\.state) == [.waiting(.unarmed)])
			let token = try await relaunch.turns.armedToken(on: relaunch.coach)
			#expect(await relaunch.coach.decide(.save(token), in: .main) == .saved)
			let claim = try #require(try await relaunch.turns.claims(in: relaunch.log).first).1
			#expect(try await SavedPlanRows.stored(claim.savedPlan, in: relaunch.log).count == 1)
			#expect(try await SavedPlanRows.stored(in: relaunch.log).count == 1)
		}

		@Test func aSavedPlanIsInThePromptAndItsCardReadsSavedAfterTheRelaunch() async throws {
			let rig = try PlanCrashRig()
			_ = try await rig.stop(.s5)
			let relaunch = try await rig.relaunch()
			await relaunch.coach.lifecycle(.becameActive)

			#expect(try await relaunch.turns.cards(on: relaunch.coach).map(\.state) == [.saved])
			#expect(try await relaunch.turns.planLoad(on: relaunch.coach) == PlanTurns.baseBuild)
			let request = try #require(relaunch.turns.transport.requests.first)
			#expect(try MemoryProbe.systemText(in: request).contains("- Name: Base Build"))
		}

		@Test func aStalledSaveLandsOnTheNextRecoverBehindTheNewerSave() async throws {
			let faults = FaultInjectingRecordLog(wrapping: turns.store)
			let coach = await turns.coach(over: faults)
			let first = try await turns.prepareAndArm(PlanCrashRig.earlier, on: coach)
			#expect(await coach.decide(.save(first), in: .main) == .saved)
			try faults.failAppend(ofKind: SavedPlans.kind.rawValue, skipping: 0)
			let stalled = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
			#expect(await coach.decide(.save(stalled), in: .main) == .storageUnavailable)
			let later = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
			#expect(await coach.decide(.save(later), in: .main) == .saved)
			#expect(
				try await turns.cards(on: coach).map(\.state) == [
					.saved, .storageUnavailable, .saved,
				])
			let claim = try #require(
				try await turns.claims(in: turns.store).first {
					$0.0.body.confirmation == stalled.ref.confirmation
				}
			).1

			await coach.lifecycle(.becameActive)

			#expect(try await turns.cards(on: coach).map(\.state) == [.saved, .saved, .saved])
			#expect(try await SavedPlanRows.stored(claim.savedPlan, in: turns.store).count == 1)
			#expect(try await turns.savedPlanRows() == 3)
			#expect(try await turns.planLoad(on: coach) == PlanTurns.baseBuild)
			#expect(
				try await turns.planHistory(on: coach) == [
					"Winter Base", "Threshold Block", "Base Build",
				])
		}

		@Test func recoveryDuringAnInProcessSaveWritesThePlanOnce() async throws {
			let log = HeldAppendLog(
				inner: turns.store, holding: SavedPlans.kind.rawValue, occurrence: 1)
			let coach = await turns.coach(over: log)
			let token = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
			let saving = Task { await coach.decide(.save(token), in: .main) }
			try await log.waitUntilReached()

			let recovered = Flag()
			let recovering = Task {
				await coach.lifecycle(.becameActive)
				recovered.raise()
			}
			let deadline = ContinuousClock.now + TestWaitLimit.subject(.seconds(2)).duration
			while !recovered.raised, ContinuousClock.now < deadline {
				try await Task.sleep(for: .milliseconds(10))
			}
			log.release()
			await recovering.value

			#expect(await saving.value == .saved)
			let claim = try #require(try await turns.claims(in: turns.store).first).1
			#expect(try await SavedPlanRows.stored(claim.savedPlan, in: turns.store).count == 1)
			#expect(try await turns.cards(on: coach).map(\.state) == [.saved])
		}
	}
}
