import Testing

@testable import EnduragentCoach

@Suite struct ChatRecordFailureTests {
	@Test(arguments: [false, true])
	func failedSettlementSurvivesRecoveryAndReopening(recoverBeforeReopening: Bool) async throws {
		let store = InMemoryRecordLog()
		let faults = FaultInjectingRecordLog(wrapping: store)
		let answer = "Keep this exact reply.\nTwo rides, 3 h 10 min."
		let transport = FakeModelTransport { text, _ in
			if text == "What did my week look like?" {
				faults.failSyncedAppends = true
				return ScriptedReply([.text(answer), .finish(reason: .stop)])
			}
			return ScriptedReply([.text("Next answer"), .finish(reason: .stop)])
		}
		let coach = await makeCoach(transport: transport, store: faults)
		let turn = try #require(
			try await coach.send(draft("What did my week look like?"), to: .main).acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == answer)
		faults.failSyncedAppends = false
		if recoverBeforeReopening {
			_ = try await coach.sendAndSettle("Next question")
		}
		await coach.lifecycle(.willTerminate)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: faults)
		#expect(replyText(try #require(await reopened.state(of: turn))) == answer)
		#expect(try await settlements(of: turn, in: store).count == 1)
		await reopened.lifecycle(.willTerminate)
	}
}

extension FirstTurnTests {
	@Test func failedReviewRefreshKeepsTheCardUntilASuccessfulRead() async throws {
		let faults = FaultInjectingRecordLog(wrapping: store)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: faults, clock: clock)
		let proposed = try await proposeEnduranceRide(coach)
		#expect(await coach.decide(.presented(proposed.ref), in: .main) == .presentationRecorded)
		let ready = try #require(await coach.currentSnapshot(.main)?.review)
		guard case .approveOrCancel = ready.controls else {
			Issue.record("presented review has no approval controls")
			return
		}
		faults.failFetches = true
		_ = await coach.decide(.presented(ready.ref), in: .main)
		let failed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(failed.ref == ready.ref)
		#expect(failed.cards == ready.cards)
		#expect(failed.controls == .none)
		#expect(failed.notice != nil)
		faults.failFetches = false
		_ = await coach.decide(.checkAgain(failed.ref), in: .main)
		#expect(await coach.currentSnapshot(.main)?.review == ready)
		guard case .approveOrCancel(let token) = ready.controls else { return }
		#expect(await coach.decide(.cancel(token), in: .main) == .canceled(kept: []))
		#expect(await coach.currentSnapshot(.main)?.review == nil)
	}
}
