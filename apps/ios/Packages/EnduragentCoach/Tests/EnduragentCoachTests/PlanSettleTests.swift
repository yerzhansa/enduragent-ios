import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

@Suite struct PlanSettleTests {
	let turns = PlanTurns()

	enum Ending: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case fails
		case isStopped

		var testDescription: String { rawValue }
	}

	@Test func aReplyThatEndsWellLeavesOneConfirmationThatExpiresTenMinutesAfterTheSettle()
		async throws
	{
		let coach = await turns.coach()
		let called = turns.clock.now
		let save = turns.save(PlanTurns.baseBuild)
		turns.transport.respond = { request in
			guard request.purpose == .chat else { return ScriptedReply([]) }
			return request.step == 0
				? ScriptedReply([save, .finish(reason: .toolCalls)])
				: ScriptedReply(
					[.text("Ready."), .finish(reason: .stop)], requestDelay: .seconds(90))
		}

		let turn = try #require(
			try await coach.send(draft("Save my plan"), to: .main).acceptedTurn)
		try await turns.clock.waitUntilHeld(.seconds(90))
		turns.clock.release(.seconds(90))
		let state = try #require(await coach.settledState(of: turn, in: .main))

		#expect(replyText(state) == "Ready.")
		#expect(
			try turns.toolData() == [
				.object([
					"pendingConfirmation": .bool(true),
					"summary": .string(
						"Save the training plan — replaces the current saved plan — Base Build"),
				])
			])
		let records = try await turns.store.fetch(.planChain(of: .main)).records
		try #require(records.count == 1)
		let record = try #require(records.first)
		let claim = try #require(try await claims(of: turn, in: turns.store).first)
		#expect(record.cause == claim.cause)
		#expect(record.account == claim.account)
		let step = try #require(PlanStepRecord(record))
		#expect(step.body.origin.turn == turn)
		guard case .prepared(let prepared) = step.body.step else {
			Issue.record("expected a prepared step, got \(step.body.step)")
			return
		}
		#expect(prepared.expiresAt == called.addingTimeInterval(690))
		#expect(
			prepared.document
				== (try PlanDocument.parse(arguments: .object(["plan": PlanTurns.baseBuild]))))
		#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [nil])
		#expect(try await turns.view(of: turn, on: coach).planSaveNotice == nil)
		#expect(try await turns.savedPlanRows() == 0)
		#expect(turns.calendarWrites().isEmpty)
	}

	@Test func aLaterPlanSaveInTheSameAttemptReplacesTheHeldPlan() async throws {
		let coach = await turns.coach()

		_ = try await turns.reply(
			after: [[turns.save(PlanTurns.baseBuild)], [turns.save(PlanTurns.threshold)]],
			on: coach)

		#expect(
			try await turns.prepared(in: turns.store).map(\.document) == [
				try PlanDocument.parse(arguments: .object(["plan": PlanTurns.threshold]))
			])
	}

	@Test func twoPlanSavesInOneStepAreRefusedWithEveryLaterCallOfTheAttempt() async throws {
		let coach = await turns.coach()

		let turn = try await turns.reply(
			after: [
				[turns.save(PlanTurns.baseBuild), turns.save(PlanTurns.threshold)],
				[turns.save(PlanTurns.baseBuild)],
			], on: coach)

		let refusal = JSONValue.object([
			"error": .string("concurrent_plan_save"),
			"details": .string("Call plan_save once per step. Nothing was prepared."),
		])
		#expect(try turns.toolData() == [refusal, refusal, refusal])
		#expect(try await turns.steps(in: turns.store).isEmpty)
		#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [.refused])
		#expect(try await turns.view(of: turn, on: coach).planSaveNotice == PlanTurns.notPrepared)
	}

	@Test(arguments: Ending.allCases)
	func aTurnThatSavesAPlanAndDoesNotFinishLeavesNoConfirmationAndSaysSo(_ ending: Ending)
		async throws
	{
		let coach = await turns.coach()
		let saved = [turns.save(PlanTurns.baseBuild), .finish(reason: .toolCalls)]
		switch ending {
		case .fails: turns.script(saved + [.fail(.http(status: 401))])
		case .isStopped: turns.script(saved + [.hang])
		}
		let turn = try #require(
			try await coach.send(draft("Save my plan"), to: .main).acceptedTurn)
		if ending == .isStopped {
			try await waitUntil { turns.transport.requests.count >= 2 }
			await coach.stop(.main)
		}

		let state = try #require(await coach.settledState(of: turn, in: .main))

		#expect(replyText(state) == nil)
		#expect(try await turns.steps(in: turns.store).isEmpty)
		#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [.turnDidNotFinish])
		#expect(try await turns.view(of: turn, on: coach).planSaveNotice == PlanTurns.notPrepared)
	}

	@Test(arguments: ["I ran out of steps.", ""])
	func aStepLimitSummaryReplyKeepsTheConfirmation(summary: String) async throws {
		let coach = await turns.coach()
		let load: [ScriptedEvent] = [
			.toolCall(name: "plan_load", arguments: "{}"), .finish(reason: .toolCalls),
		]
		turns.script(
			[turns.save(PlanTurns.baseBuild), .finish(reason: .toolCalls)]
				+ Array(repeating: load, count: 9).flatMap { $0 }
				+ (summary.isEmpty ? [] : [.text(summary)]) + [.finish(reason: .stop)])

		let state = try await coach.sendAndSettle("Save my plan")

		let turn = try #require(await coach.currentSnapshot(.main)?.turns.first?.id)
		#expect(replyText(state) == (summary.isEmpty ? nil : summary))
		guard case .replied(let reply, _)? = try await turns.settled(turn).first?.settlement else {
			Issue.record("expected a reply")
			return
		}
		#expect(
			reply
				== (summary.isEmpty ? .catalog(Catalog.coachFallbackStepLimit) : .model(summary)))
		#expect(try await turns.prepared(in: turns.store).count == 1)
		#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [nil])
	}

	@Test func aConfirmationThatCannotBeStoredIsReportedBesideTheAnsweredReply() async throws {
		let faults = FaultInjectingRecordLog(wrapping: turns.store)
		try faults.failAppends(ofKind: PlanChain.kind.rawValue)
		let coach = await turns.coach(over: faults)

		let turn = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		#expect(try await turns.steps(in: turns.store).isEmpty)
		#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [.notSaved])
		#expect(try await turns.view(of: turn, on: coach).planSaveNotice == PlanTurns.notPrepared)
		#expect(
			coach.diagnostics.entries.contains {
				$0.event == .planConfirmationUnavailable(.main, .rejectedBatch)
			})
	}

	@Test(arguments: [Plans.settleAppendAttempts - 1, Plans.settleAppendAttempts])
	func theSettleRereadsAMovedHeadUpToItsAttemptLimit(moves: Int) async throws {
		let log = InterleavingChainLog(turns.store)
		let store = turns.store
		log.interleave(on: .planChain(of: .main), times: moves) {
			try await PlanTurns.moveHead(of: store, foreign: 100 + log.interleaved)
		}
		let coach = await turns.coach(over: log)

		let turn = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		#expect(log.interleaved == moves)
		let steps = try await turns.steps(in: turns.store)
		if moves < Plans.settleAppendAttempts {
			#expect(steps.count == moves + 1)
			guard case .prepared? = steps.last?.body.step else {
				Issue.record("expected the prepared step last, got \(steps)")
				return
			}
			#expect(steps.last?.body.origin.turn == turn)
			#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [nil])
			#expect(try await turns.view(of: turn, on: coach).planSaveNotice == nil)
		} else {
			#expect(steps.count == moves)
			#expect(try await turns.prepared(in: turns.store).isEmpty)
			#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [.notSaved])
			#expect(
				try await turns.view(of: turn, on: coach).planSaveNotice == PlanTurns.notPrepared)
		}
	}

	@Test func anUnconnectedTurnOnADeviceThatConnectedBeforeGetsPlanUnavailable() async throws {
		try await turns.store.append(
			[
				storedRecord(
					device: turns.store.deviceId, wall: 1, ulid: fixedUlid(1),
					account: testConnection.account, body: .synced(.trainingIdentityObserved))
			], locality: .synced)
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		let coach = await turns.coach(secrets: secrets)

		let turn = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		#expect(
			try turns.toolData().map { $0.objectFields["error"] } == [.string("plan_unavailable")])
		#expect(try await turns.steps(in: turns.store).isEmpty)
		#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [nil])
	}

	@Test func aWaitingConfirmationIsOneUnarmedCardUnderItsTurnNamingThePlanItReplaces()
		async throws
	{
		try await turns.store.append(
			[
				storedRecord(
					device: turns.store.deviceId, wall: 1, ulid: fixedUlid(1),
					account: testConnection.account,
					body: try SavedPlanRows.body(PlanTurns.threshold))
			], locality: .synced)
		let coach = await turns.coach()

		let turn = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		let cards = try await coach.plans.snapshot(chat: .main)
		try #require(cards.count == 1)
		let card = try #require(cards.first)
		#expect(card.placement == .afterTurn(turn))
		#expect(card.state == .waiting(.unarmed))
		#expect(
			card.summary
				== PlanSummary(
					name: "Base Build", goal: "Gran fondo", weeks: 12,
					phases: [
						PlanPhaseRow(focus: "base_building", weeks: 8, hours: 7.5),
						PlanPhaseRow(focus: "taper", weeks: 4, hours: nil),
					], replaces: "Threshold Block"))
		#expect(card.ref.chat == .main)
		#expect(
			card.ref.digest
				== (try PlanDocument.parse(arguments: .object(["plan": PlanTurns.baseBuild])))
				.digest)
	}

	@Test func theWakeTenMinutesAfterTheSettleExpiresTheCard() async throws {
		let coach = await turns.coach()
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		#expect(try await turns.cards(on: coach).map(\.state) == [.waiting(.unarmed)])

		try await turns.clock.waitUntilHeld(.seconds(600))
		turns.clock.release(.seconds(600))

		#expect(try await turns.waitForCards(on: coach) { $0.map(\.state) == [.expired] } != nil)
	}

	@Test func aWaitingCardIsCarriedOnceToTheTopAfterNewConversation() async throws {
		let coach = await turns.coach()
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

		_ = await coach.resetAndSettle(in: .main)

		let cards = try await coach.plans.snapshot(chat: .main)
		#expect(cards.map(\.placement) == [.preparedEarlier])
		#expect(cards.map(\.state) == [.waiting(.unarmed)])
	}

	@Test func aKillAfterThePlanConfirmationWasStoredCountsItAndRefusesTryAgain() async throws {
		let dying = FaultInjectingRecordLog(wrapping: turns.store)
		for kind in ["turnSettled", "pendingSettlement"] {
			try dying.failAppends(ofKind: kind)
		}
		let before = await turns.coach(over: dying)
		let turn = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: before)
		#expect(try await turns.prepared(in: turns.store).count == 1)
		try await before.dieWithoutWriting(to: dying)

		let after = await turns.coach()
		await after.lifecycle(.becameActive)

		#expect(
			try await turns.settled(turn).map(\.settlement) == [
				.interrupted(
					partial: "", cause: .processEnded,
					saved: WriteSummary(
						memorySections: 0, ledgerEvents: 0, planConfirmations: 1,
						calendarWrites: 0))
			])
		#expect(try await turns.settled(turn).map(\.planSaveNotPrepared) == [nil])
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await after.retry(turn, in: .main)
		}
	}

	@Test func aKillBeforeThePlanConfirmationWasStoredLeavesNothingWaitingAndOffersTryAgain()
		async throws
	{
		let dying = FaultInjectingRecordLog(wrapping: turns.store)
		let before = await turns.coach(over: dying)
		turns.script([turns.save(PlanTurns.baseBuild), .finish(reason: .toolCalls), .hang])
		let turn = try #require(
			try await before.send(draft("Save my plan"), to: .main).acceptedTurn)
		try await waitUntil { turns.transport.requests.count >= 2 }
		try await before.dieWithoutWriting(to: dying)

		let after = await turns.coach()
		await after.lifecycle(.becameActive)

		#expect(
			try await turns.settled(turn).map(\.settlement) == [
				.interrupted(partial: "", cause: .processEnded, saved: .none)
			])
		#expect(try await turns.steps(in: turns.store).isEmpty)
		guard case .interrupted(let interrupted)? = await after.state(of: turn) else {
			Issue.record("expected an interrupted turn")
			return
		}
		#expect(interrupted.notice.actions == [.tryAgain(turn)])
	}
}

extension SwiftDataSuites {
	@Suite struct PlanSettleStorageTests {
		@Test func anUnreadableChainHeadRecordsNotSavedBesideTheAnsweredReply() async throws {
			let turns = PlanTurns()
			let directory = try TestTemporaryFolders.make()
			let local = try ModelContainerHandle.deviceLocal(directory: directory)
			let log = SwiftDataRecordLog(
				deviceId: turns.store.deviceId,
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName)),
				local: local)
			let foreign = storedRecord(
				device: PlanStepRows.phone, wall: 1, ulid: fixedUlid(100),
				body: try PlanStepRows(confirmation: 100, turn: 101).canceled())
			try await log.append([foreign], locality: .deviceLocal)
			let context = ModelContext(local.container)
			let ulid = foreign.ulid.rawValue
			let row = try #require(
				try context.fetch(
					FetchDescriptor<StoredAthleteRecord>(predicate: #Predicate { $0.ulid == ulid })
				).first)
			row.bodyVersion = 99
			try context.save()
			let coach = await turns.coach(over: log)

			let turn = try await turns.reply(
				after: [[turns.save(PlanTurns.baseBuild)]], on: coach)

			#expect(try await turns.steps(in: log).isEmpty)
			let settled = try await log.fetch(
				RecordQuery(scope: .synced([.turnSettled]), turn: turn)
			).records.compactMap { record -> TurnSettledBody? in
				guard case .synced(.turnSettled(let body)) = record.body else { return nil }
				return body
			}
			#expect(settled.map(\.planSaveNotPrepared) == [.notSaved])
			#expect(
				try await turns.view(of: turn, on: coach).planSaveNotice == PlanTurns.notPrepared)
		}
	}
}
