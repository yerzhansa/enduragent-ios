import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanConfirmationTests {
	let turns = PlanTurns()

	@Test func aCardArmsOnlyWhenItsOwnDeliveryIsPresented() async throws {
		let coach = await turns.coach()
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		let card = try #require(try await turns.cards(on: coach).first)
		#expect(card.state == .waiting(.unarmed))
		let otherDigest = PlanCardRef(
			chat: card.ref.chat, confirmation: card.ref.confirmation,
			digest: try PlanTurns.document(PlanTurns.threshold).digest,
			delivery: card.ref.delivery)

		#expect(
			await coach.decide(.presented(otherDigest), in: .main) == .notSaved(.notPresented))
		#expect(try await turns.cards(on: coach).map(\.state) == [.waiting(.unarmed)])

		#expect(await coach.decide(.presented(card.ref), in: .main) == .presented)
		let token = try #require(PlanTurns.token(of: try await turns.cards(on: coach).first))
		#expect(token.ref == card.ref)

		let later = await turns.coach()
		_ = try await turns.armedToken(on: later)
		#expect(await later.decide(.save(token), in: .main) == .notSaved(.notPresented))
		#expect(await later.decide(.cancel(token), in: .main) == .notSaved(.notPresented))
		#expect(try await turns.steps(in: turns.store).count == 1)
		#expect(try await turns.savedPlanRows() == 0)
	}

	@Test func savePlanClaimsThenCommitsOneSavedPlanStampedForTheConfirmation() async throws {
		let coach = await turns.coach()
		let token = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		let prepared = try #require(try await turns.prepared(in: turns.store).first)

		#expect(await coach.decide(.save(token), in: .main) == .saved)

		let steps = try await turns.steps(in: turns.store)
		#expect(steps.allSatisfy { $0.body.confirmation == token.ref.confirmation })
		let (claimRecord, claim) = try #require(try await turns.claims(in: turns.store).first)
		#expect(
			Array(steps.map(\.body.step).dropFirst()) == [.claimed(claim), .saved(claim.savedPlan)])
		let rows = try await SavedPlanRows.stored(in: turns.store)
		try #require(rows.count == 1)
		let row = try #require(rows.first)
		#expect(row.payload.objectFields["id"] == .string(claim.savedPlan.ulid.rawValue))
		#expect(row.payload.objectFields["decided"] == SavedPlanRows.payload(of: claimRecord.hlc))
		#expect(
			row.payload.objectFields["confirmation"]
				== .string(token.ref.confirmation.ulid.rawValue))
		#expect(row.record.cause == .operation(.planSave(token.ref.confirmation), claim.attempt))
		#expect(row.record.account == prepared.account)
		#expect(row.record.account == testConnection.account)
		#expect(try await turns.cards(on: coach).map(\.state) == [.saved])

		#expect(await coach.decide(.save(token), in: .main) == .notSaved(.alreadyDecided))
		#expect(await coach.decide(.cancel(token), in: .main) == .notSaved(.alreadyDecided))
		#expect(try await turns.steps(in: turns.store).count == 3)
		#expect(try await turns.savedPlanRows() == 1)

		let loaded = try await turns.planLoad(on: coach)
		#expect(canonicalJSON(loaded) == (try PlanTurns.document(PlanTurns.baseBuild)).text)
		#expect(loaded == PlanTurns.baseBuild)
	}

	@Test func twoSaveTapsOnOneCardLeaveOneClaimAndOneSavedPlan() async throws {
		let log = InterleavingChainLog(turns.store)
		let coach = await turns.coach(over: log)
		let token = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		let inner = PlanOutcomes()
		log.interleave(on: .planChain(of: .main), times: 1) {
			inner.record(await coach.decide(.save(token), in: .main))
		}

		let outer = await coach.decide(.save(token), in: .main)

		#expect(log.interleaved == 1)
		#expect(inner.all == [.saved])
		#expect(outer == .notSaved(.alreadyDecided))
		let claims = try await turns.claims(in: turns.store)
		try #require(claims.count == 1)
		let claim = try #require(claims.first).1
		#expect(try await SavedPlanRows.stored(claim.savedPlan, in: turns.store).count == 1)
		#expect(try await turns.savedPlanRows() == 1)
	}

	@Test func cancelWritesNoPlanAndALaterSaveReplacesTheSavedPlanInHistory() async throws {
		let coach = await turns.coach()
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		#expect(await coach.decide(.save(first), in: .main) == .saved)

		let canceled = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		#expect(await coach.decide(.cancel(canceled), in: .main) == .canceled)

		guard case .canceled? = try await turns.steps(in: turns.store).last?.body.step else {
			Issue.record("Cancel did not append a canceled step")
			return
		}
		#expect(try await turns.cards(on: coach).map(\.state) == [.saved, .canceled])
		#expect(try await turns.savedPlanRows() == 1)
		#expect(try await turns.planLoad(on: coach) == PlanTurns.threshold)
		#expect(await coach.decide(.save(canceled), in: .main) == .notSaved(.alreadyDecided))

		let second = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		#expect(await coach.decide(.save(second), in: .main) == .saved)

		#expect(try await turns.savedPlanRows() == 2)
		#expect(try await turns.planLoad(on: coach) == PlanTurns.baseBuild)
		let history = try await turns.tools(
			[
				.toolCall(
					name: "memory_query", arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#)
			], on: coach)
		let lines = try #require(history.first?.stringValue).split(separator: "\n")
		let replaced = lines.filter { $0.hasPrefix("history: save-plan — was: {") }
		try #require(replaced.count == 1)
		let line = try #require(replaced.first)
		let halves = line.components(separatedBy: " / now: ")
		#expect(halves.count == 2)
		#expect(halves.first?.contains(#""name": "Threshold Block""#) == true)
		#expect(halves.last?.contains(#""name": "Base Build""#) == true)
	}

	@Test func aNewerConfirmationMakesTheOlderCardExpiredAndItsSaveReplaced() async throws {
		let coach = await turns.coach()
		let older = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)

		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		let cards = try await turns.cards(on: coach)
		#expect(cards.map(\.state) == [.expired, .waiting(.unarmed)])
		#expect(cards.first?.id == older.ref.confirmation)
		#expect(await coach.decide(.save(older), in: .main) == .notSaved(.replaced))
		#expect(await coach.decide(.cancel(older), in: .main) == .notSaved(.replaced))
		#expect(try await turns.steps(in: turns.store).count == 2)
		#expect(try await turns.savedPlanRows() == 0)
	}

	@Test func savePlanAfterTheAppSwitchesToAnotherAthleteIsRefused() async throws {
		let coach = await turns.coach()
		let token = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		turns.intervals.athlete = .cyclist(id: "i2002", name: "Bo", ftp: 200)

		guard
			case .replaced = await coach.changeTraining(
				.replaceConfirmingAthleteSwitch(apiKey: "icu-other-key", athlete: .keyOwner))
		else {
			Issue.record("the athlete switch did not replace the connection")
			return
		}

		#expect(await coach.decide(.save(token), in: .main) == .notSaved(.athleteChanged))
		#expect(try await turns.steps(in: turns.store).count == 1)
		#expect(try await turns.savedPlanRows() == 0)
	}
}
