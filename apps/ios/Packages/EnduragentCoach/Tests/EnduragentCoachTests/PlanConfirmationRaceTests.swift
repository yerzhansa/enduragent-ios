import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension PlanConfirmationTests {
	@Test func aSaveThatClaimsBeforeTheNextSettleAppendsKeepsItsPlanAndTheNewCardWaits()
		async throws
	{
		let log = InterleavingChainLog(turns.store)
		let coach = await turns.coach(over: log)
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		let saved = PlanOutcomes()
		log.interleave(on: .planChain(of: .main), times: 1) {
			saved.record(await coach.decide(.save(first), in: .main))
		}

		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		#expect(log.interleaved == 1)
		#expect(saved.all == [.saved])
		#expect(try await turns.cards(on: coach).map(\.state) == [.saved, .waiting(.unarmed)])
		#expect(try await turns.prepared(in: turns.store).count == 2)
		#expect(try await turns.savedPlanRows() == 1)
		#expect(try await turns.planLoad(on: coach) == PlanTurns.threshold)
	}

	@Test func aSettleThatAppendsBeforeTheClaimMakesTheSaveReplaced() async throws {
		let log = InterleavingChainLog(turns.store)
		let coach = await turns.coach(over: log)
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		let turns = turns
		log.interleave(on: .planChain(of: .main), times: 1) {
			_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		}

		let outcome = await coach.decide(.save(first), in: .main)

		#expect(log.interleaved == 1)
		#expect(outcome == .notSaved(.replaced))
		#expect(try await turns.claims(in: turns.store).isEmpty)
		#expect(try await turns.savedPlanRows() == 0)
		#expect(try await turns.cards(on: coach).map(\.state) == [.expired, .waiting(.unarmed)])
	}

	@Test(arguments: [599, 600])
	func saveWorksUntilTheTenMinutesEndAndTheWakeExpiresTheCardAtThem(seconds: Int)
		async throws
	{
		let coach = await turns.coach()
		let token = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		try await turns.clock.waitUntilHeld(.seconds(600))

		turns.clock.advance(by: .seconds(seconds))

		if seconds < 600 {
			#expect(await coach.decide(.save(token), in: .main) == .saved)
			#expect(try await turns.savedPlanRows() == 1)
			return
		}
		#expect(try await turns.waitForCards(on: coach) { $0.map(\.state) == [.expired] } != nil)
		#expect(await coach.decide(.save(token), in: .main) == .notSaved(.expired))
		#expect(await coach.decide(.cancel(token), in: .main) == .notSaved(.expired))
		#expect(try await turns.steps(in: turns.store).count == 1)
		#expect(try await turns.savedPlanRows() == 0)
	}

	@Test func aSaveStalledByStorageMarksOnlyItsCardWhileAnotherConfirmationSaves() async throws {
		let faults = FaultInjectingRecordLog(wrapping: turns.store)
		try faults.failAppend(ofKind: SavedPlans.kind.rawValue, skipping: 0)
		let coach = await turns.coach(over: faults)
		let stalled = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)

		#expect(await coach.decide(.save(stalled), in: .main) == .storageUnavailable)

		#expect(try await turns.cards(on: coach).map(\.state) == [.storageUnavailable])
		#expect(
			coach.diagnostics.entries.contains {
				$0.event == .planSaveStalled(stalled.ref.confirmation, .rejectedBatch)
			})
		#expect(try await turns.claims(in: turns.store).count == 1)
		#expect(try await turns.savedPlanRows() == 0)

		let next = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		#expect(await coach.decide(.save(next), in: .main) == .saved)

		#expect(
			try await turns.cards(on: coach).map(\.state) == [.storageUnavailable, .saved])
		#expect(try await turns.savedPlanRows() == 1)
		#expect(try await turns.planLoad(on: coach) == PlanTurns.baseBuild)
	}
}
