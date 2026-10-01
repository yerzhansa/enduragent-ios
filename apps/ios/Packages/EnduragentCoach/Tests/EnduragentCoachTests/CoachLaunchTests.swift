import Testing

@testable import EnduragentCoach

@Suite struct CoachLaunchTests {
	@Test func concurrentObservationAndSendShareTheInitialRead() async throws {
		let inner = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		try await seedHistory(inner, clock: clock, turns: 1, tokens: 40)
		let recording = BatchRecordingLog(inner: inner)
		let held = HeldConversationReadLog(inner: recording)
		defer { held.gate.release() }
		let transport = FakeModelTransport()
		transport.script = [.text("New answer"), .finish(reason: .stop)]
		let coach = await makeCoach(transport: transport, store: held, clock: clock)
		async let observed = coach.currentSnapshot(.main)
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		let message = draft("New question")
		async let first = coach.send(message, to: .main)
		async let second = coach.send(message, to: .main)
		held.gate.release()
		_ = await observed
		let turn = try #require(try await first.acceptedTurn)
		#expect(try await second.acceptedTurn == turn)
		#expect(
			replyText(try #require(await coach.settledState(of: turn, in: .main))) == "New answer")
		#expect(try #require(await coach.currentSnapshot(.main)).turns.count == 2)
		#expect(transport.requests.count == 1)
		#expect(recording.reads.filter { $0 == ConversationFold.syncedScope }.count == 1)
	}

	@Test func launchFoldsTheChatOnce() async throws {
		let inner = InMemoryRecordLog()
		let transport = FakeModelTransport()
		transport.script = [
			.text("Stored answer"), .finish(reason: .stop),
			.text("Second answer"), .finish(reason: .stop),
		]
		let prior = await makeCoach(transport: transport, store: inner)
		_ = try await prior.sendAndSettle("Stored question")
		_ = try await prior.sendAndSettle("Second question")
		await prior.lifecycle(.willTerminate)
		let store = BatchRecordingLog(inner: inner)
		let coach = await makeCoach(transport: FakeModelTransport(), store: store, consent: false)
		#expect(await coach.languagePreference() == .automatic)
		var snapshots = await coach.observe(.main).makeAsyncIterator()
		let snapshot = try #require(await snapshots.next())
		#expect(snapshot.turns.map(\.athleteText) == ["Stored question", "Second question"])
		#expect(
			snapshot.turns.map(\.state).compactMap(replyText) == ["Stored answer", "Second answer"])
		let conversationReads = store.fetches.filter {
			[ConversationFold.syncedScope, ConversationFold.localScope, TurnRecovery.localScope]
				.contains($0.query.scope)
		}
		let ulids = conversationReads.flatMap(\.ulids)
		#expect(ulids.count == 8)
		#expect(Set(ulids).count == ulids.count)
		#expect(store.reads.filter { $0 == ConversationFold.syncedScope }.count == 1)
		#expect(store.cursorReads == [.synced, .deviceLocal])
		#expect(transport.requests.count == 2)
	}
}
