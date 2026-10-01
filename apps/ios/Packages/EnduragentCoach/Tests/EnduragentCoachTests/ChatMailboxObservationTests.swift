import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

extension ChatMailboxTests {
	@Test func observeAfterPreloadPublishSeesLoadedTurns() async throws {
		let store = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let turn = TurnID(ulid: fixedUlid(1))
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 1, ulid: turn.ulid,
					body: .synced(sampleUser(chatId: .main, text: "Thursday?", turn: turn)))
			])
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		store.failFetches = true
		let failed = try #require(await coach.currentSnapshot(.main))
		#expect(failed.turns.isEmpty)
		_ = await coach.changeTraining(.disconnect)
		store.failFetches = false
		let loaded = try #require(await coach.currentSnapshot(.main))
		#expect(loaded.turns.map(\.id) == [turn])
		#expect(loaded.turns.first?.athleteText == "Thursday?")
	}

	@Test func slowSubscriberSeesStopSettlement() async throws {
		let pacing = HeldClock()
		let transport = FakeModelTransport(clock: pacing)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday "), .text("is on."), .finish(reason: .stop)],
			deltaDelay: .milliseconds(1), otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		var slow = await coach.observe(.main).makeAsyncIterator()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		try await pacing.waitUntilHeld(.milliseconds(1))
		pacing.advance(by: .milliseconds(1))
		await coach.waitForLiveText(turn)
		try await pacing.waitUntilHeld(.milliseconds(1))
		await coach.stop(.main)
		let next = try #require(await slow.next())
		guard case .interrupted(let interrupted)? = next.turns.first?.state else {
			Issue.record("The slow subscriber missed the Stop settlement")
			return
		}
		#expect(next.turns.first?.id == turn)
		#expect(interrupted.partial == "Thursday ")
		#expect(interrupted.cause == .athleteStopped)
		#expect(next.liveReply == nil)
		#expect(next.activity == .idle)
	}

	@Test func slowSubscriberSeesFailureSettlement() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday "), .fail(.http(status: 401))], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		var slow = await coach.observe(.main).makeAsyncIterator()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(failure(settled) == .model(.credentialRejected(.credits)))
		let next = try #require(await slow.next())
		#expect(next.turns.first?.id == turn)
		#expect(next.turns.first?.state == settled)
		#expect(next.liveReply == nil)
		#expect(next.activity == .idle)
	}
}
