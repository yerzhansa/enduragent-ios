import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct ChatRecordFailureTests {
	@Test(arguments: [false, true])
	func fetchFailureAtSettlementStillPersistsTheExactReply(useLocalCopy: Bool) async throws {
		let store = InMemoryRecordLog()
		let faults = FaultInjectingRecordLog(wrapping: store)
		let answer = "Keep this exact reply.\nTwo rides, 3 h 10 min."
		let transport = FakeModelTransport { _ in
			faults.failFetches = true
			faults.failSyncedAppends = useLocalCopy
			return ScriptedReply([.text(answer), .finish(reason: .stop)])
		}
		let coach = await makeCoach(transport: transport, store: faults)
		let turn = try #require(
			try await coach.send(draft("What did my week look like?"), to: .main).acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == answer)
		let synced = try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn))
		let local = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.pendingSettlement]), turn: turn))
		#expect(synced.records.count == (useLocalCopy ? 0 : 1))
		#expect(local.records.count == (useLocalCopy ? 1 : 0))
		#expect(
			await coach.currentSnapshot(.main)?.turns.first?.saveFailure
				== (useLocalCopy ? Catalog.chatNoticeReplyUnsaved : nil))
		await coach.lifecycle(.willTerminate)
		faults.failFetches = false
		let reopened = await makeCoach(transport: FakeModelTransport(), store: faults)
		#expect(replyText(try #require(await reopened.state(of: turn))) == answer)
		await reopened.lifecycle(.willTerminate)
		faults.failSyncedAppends = false
		let recovered = await makeCoach(transport: FakeModelTransport(), store: faults)
		#expect(replyText(try #require(await recovered.state(of: turn))) == answer)
		#expect(try await settlements(of: turn, in: store).count == 1)
		#expect(await recovered.currentSnapshot(.main)?.turns.first?.saveFailure == nil)
		#expect(transport.requestCount == 1)
		await recovered.lifecycle(.willTerminate)
	}

	@Test(arguments: [false, true], [false, true])
	func failedSettlementSurvivesRecoveryAndReopening(
		recoverBeforeReopening: Bool, lostAcknowledgment: Bool
	) async throws {
		let store = InMemoryRecordLog()
		let faults = FaultInjectingRecordLog(wrapping: store)
		let answer = "Keep this exact reply.\nTwo rides, 3 h 10 min."
		let transport = FakeModelTransport { request in
			if request.text == "What did my week look like?" {
				faults.failSyncedAppends = !lostAcknowledgment
				faults.failSyncedAcknowledgments = lostAcknowledgment
				return ScriptedReply([.text(answer), .finish(reason: .stop)])
			}
			return ScriptedReply([.text("Next answer"), .finish(reason: .stop)])
		}
		let coach = await makeCoach(transport: transport, store: faults)
		let turn = try #require(
			try await coach.send(draft("What did my week look like?"), to: .main).acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == answer)
		#expect(
			await coach.currentSnapshot(.main)?.turns.first?.saveFailure
				== Catalog.chatNoticeReplyUnsaved)
		let pending = try #require(
			try await store.fetch(
				RecordQuery(scope: .deviceLocal([.pendingSettlement]), turn: turn)
			)
			.records.first)
		#expect(
			coach.diagnostics.entries.contains {
				$0.event == .settlementUnsaved(turn, .rejectedBatch)
			})
		faults.failSyncedAppends = false
		faults.failSyncedAcknowledgments = false
		if recoverBeforeReopening {
			_ = try await coach.sendAndSettle("Next question")
			#expect(await coach.currentSnapshot(.main)?.turns.first?.saveFailure == nil)
			#expect(try await settlements(of: turn, in: store).count == 1)
		}
		await coach.lifecycle(.willTerminate)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: faults)
		#expect(replyText(try #require(await reopened.state(of: turn))) == answer)
		#expect(try await settlements(of: turn, in: store).count == 1)
		let saved = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
				.first)
		#expect(saved.ulid == pending.ulid)
		#expect(saved.hlc == pending.hlc)
		#expect(saved.cause == pending.cause)
		#expect(await reopened.currentSnapshot(.main)?.turns.first?.saveFailure == nil)
		await reopened.lifecycle(.willTerminate)
		let reopenedAgain = await makeCoach(transport: FakeModelTransport(), store: faults)
		#expect(replyText(try #require(await reopenedAgain.state(of: turn))) == answer)
		#expect(try await settlements(of: turn, in: store).count == 1)
		await reopenedAgain.lifecycle(.willTerminate)
	}

	@Test func failedLocalRecoveryCopyKeepsTheReplyAndWarnsUntilTheNextSave() async throws {
		let store = InMemoryRecordLog()
		let faults = FaultInjectingRecordLog(wrapping: store)
		try faults.failAppends(ofKind: "pendingSettlement")
		let transport = FakeModelTransport { request in
			if request.text == "First question" { faults.failSyncedAppends = true }
			return ScriptedReply([.text("Reply to " + request.text), .finish(reason: .stop)])
		}
		let coach = await makeCoach(transport: transport, store: faults)
		let turn = try #require(
			try await coach.send(draft("First question"), to: .main).acceptedTurn)
		#expect(
			replyText(try #require(await coach.settledState(of: turn, in: .main)))
				== "Reply to First question")
		#expect(
			await coach.currentSnapshot(.main)?.turns.first?.saveFailure
				== Catalog.chatNoticeReplyUnsaved)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingSettlement]))).records
				.isEmpty)
		faults.failSyncedAppends = false
		_ = try await coach.sendAndSettle("Second question")
		#expect(await coach.currentSnapshot(.main)?.turns.first?.saveFailure == nil)
		await coach.lifecycle(.willTerminate)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: faults)
		#expect(
			replyText(try #require(await reopened.state(of: turn))) == "Reply to First question")
	}
}
