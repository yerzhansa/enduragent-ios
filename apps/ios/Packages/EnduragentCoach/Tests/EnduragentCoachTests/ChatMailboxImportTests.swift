import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension ChatMailboxTests {
	@Test func remoteResetRefreshesExistingObserver() async throws {
		let store = ImportingRecordLog()
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Local answer"), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Local question")
		let observed = ImportSnapshots(await coach.observe(.main))
		let reset = ResetID(ulid: fixedUlid(90))
		try await seed(
			store,
			[
				storedRecord(
					device: DeviceID(rawValue: "remote-phone"), wall: 2_000_000_000_000,
					ulid: reset.ulid,
					body: .synced(
						.windowStart(
							WindowStartBody(
								chatId: .main, firstIncludedUlid: reset.ulid, reason: .reset(reset))
						)))
			])
		store.notifyImport()
		try await waitUntil { observed.latest?.opening == .afterNewConversation(memorySaved: true) }
		#expect(observed.latest?.turns.isEmpty == true)
		let remote = try await importTurn(into: store)
		try await waitUntil { observed.latest?.turns.map(\.id) == [remote] }
		let snapshot = try #require(observed.latest)
		#expect(snapshot.turns.map(\.athleteText) == ["Remote question"])
		#expect(snapshot.opening == .continuing)
		#expect(replyText(try #require(snapshot.turns.first?.state)) == "Remote answer")
		#expect(try await coach.history().count == 1)
		let count = observed.count
		store.notifyImport()
		try await waitUntil { observed.count > count }
		let refreshed = try #require(observed.latest)
		#expect(refreshed.revision > snapshot.revision)
		var expected = snapshot
		expected.revision = refreshed.revision
		#expect(refreshed == expected)
		#expect(store.subscriptions == 1)
	}

	@Test func remoteTurnArrivingMidTurnReachesLiveConversation() async throws {
		let store = ImportingRecordLog()
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Local partial"), .hang], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		let local = try #require(
			try await coach.send(draft("Local question"), to: .main).acceptedTurn)
		await coach.waitForLiveText(local)
		let observed = ImportSnapshots(await coach.observe(.main))
		let remote = try await importTurn(into: store)
		try await waitUntil { observed.latest?.turns.contains { $0.id == remote } == true }
		let snapshot = try #require(observed.latest)
		#expect(snapshot.turns.map(\.athleteText) == ["Local question", "Remote question"])
		guard case .processing? = snapshot.turns.first?.state else {
			await coach.stop(.main)
			Issue.record("import replaced the running local turn")
			return
		}
		#expect(snapshot.liveReply?.turn == local)
		#expect(snapshot.liveReply?.text == "Local partial")
		#expect(replyText(try #require(snapshot.turns.last?.state)) == "Remote answer")
		await coach.stop(.main)
		#expect(try await settlements(of: local, in: store).count == 1)
		let settled = try await store.fetch(
			RecordQuery(scope: .synced([.turnSettled]), turn: local)
		).records
		#expect(try #require(settled.first).hlc.wallMs >= 2_000_000_000_002)
		let mailbox = try await coach.mailbox(for: .main)
		#expect(await mailbox.conversation.turn(local)?.settlements.count == 1)
		#expect(transport.requestCount == 1)
	}

	@Test func importReadKeepsALocalSettlementCommittedWhileItWaits() async throws {
		let store = ImportingRecordLog()
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Local partial"), .hang], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		let local = try #require(
			try await coach.send(draft("Local question"), to: .main).acceptedTurn)
		await coach.waitForLiveText(local)
		let observed = ImportSnapshots(await coach.observe(.main))
		let read = store.holdRead()
		defer { read.release() }
		let remote = try await importTurn(into: store)
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await read.waitUntilParked()
			} != nil,
			"Import read did not park within five seconds")
		await coach.stop(.main)
		read.release()
		try await waitUntil { observed.latest?.turns.contains { $0.id == remote } == true }
		let state = try #require(observed.latest?.turns.first { $0.id == local }?.state)
		#expect(isInterrupted(state))
		#expect(try await settlements(of: local, in: store).count == 1)
		let mailbox = try await coach.mailbox(for: .main)
		#expect(await mailbox.conversation.turn(local)?.settlements.count == 1)
		#expect(await mailbox.conversation.turn(local)?.requestText == "Local question")
	}

	@Test func importKeepsAnUnsavedSettlement() async throws {
		let inner = InMemoryRecordLog()
		let faults = FaultInjectingRecordLog(wrapping: inner)
		try faults.failAppends(ofKind: "turnSettled")
		try faults.failAppends(ofKind: "replyObserved")
		let store = ImportingRecordLog(inner: faults)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Unsaved answer"), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		let local = try #require(
			try await coach.send(draft("Local question"), to: .main).acceptedTurn)
		let before = try #require(await coach.settledState(of: local, in: .main))
		let observed = ImportSnapshots(await coach.observe(.main))
		let remote = try await importTurn(into: inner, notifying: store)
		try await waitUntil { observed.latest?.turns.contains { $0.id == remote } == true }
		#expect(observed.latest?.turns.first { $0.id == local }?.state == before)
		#expect(replyText(before) == "Unsaved answer")
		#expect(try await settlements(of: local, in: store).isEmpty)
		let mailbox = try await coach.mailbox(for: .main)
		#expect(await mailbox.conversation.turn(local)?.settlements.count == 1)
		#expect(await mailbox.conversation.turn(local)?.replyObserved.count == 1)
	}

	@Test func failedImportKeepsTheConversationAndRetriesTheNextNotification() async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let store = ImportingRecordLog(inner: faults)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Local answer"), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Local question")
		let observed = ImportSnapshots(await coach.observe(.main))
		try await waitUntil { observed.latest != nil }
		let before = observed.latest
		faults.failFetches = true
		let remote = try await importTurn(into: store)
		try await waitUntil {
			coach.diagnostics.entries.contains {
				$0.event == .importsUnavailable(.main, .unavailable)
			}
		}
		#expect(observed.latest == before)
		faults.failFetches = false
		store.notifyImport()
		try await waitUntil { observed.latest?.turns.contains { $0.id == remote } == true }
		#expect(observed.latest?.turns.map(\.athleteText) == ["Local question", "Remote question"])
		#expect(store.subscriptions == 1)
	}

	@Test func importDuringTheInitialReadReachesTheExistingObserver() async throws {
		let store = ImportingRecordLog()
		let read = store.holdRead()
		defer { read.release() }
		let coach = await makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		async let stream = coach.observe(.main)
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await read.waitUntilParked()
			} != nil,
			"Import read did not park within five seconds")
		let remote = try await importTurn(into: store)
		read.release()
		let observed = try #require(
			try await firstSnapshot(in: await stream, within: .seconds(5)) {
				$0.turns.map(\.id) == [remote]
			})
		#expect(observed.turns.map(\.athleteText) == ["Remote question"])
	}

	@Test func importSubscriptionStopsOnTermination() async throws {
		let store = ImportingRecordLog()
		let coach = await makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		_ = await coach.currentSnapshot(.main)
		_ = await coach.currentSnapshot(.main)
		#expect(store.subscriptions == 1)
		await coach.lifecycle(.willTerminate)
		try await waitUntil { store.listeners == 0 }
		_ = await coach.currentSnapshot(.main)
		#expect(store.subscriptions == 1)
	}

	@discardableResult
	private func importTurn(into store: any RecordLog, notifying imports: ImportingRecordLog? = nil)
		async throws -> TurnID
	{
		let remote = DeviceID(rawValue: "remote-phone")
		let turn = TurnID(ulid: fixedUlid(100))
		try await seed(
			store,
			[
				storedRecord(
					device: remote, wall: 2_000_000_000_001, ulid: turn.ulid,
					body: .synced(sampleUser(chatId: .main, text: "Remote question", turn: turn))),
				storedRecord(
					device: remote, wall: 2_000_000_000_002, ulid: fixedUlid(101),
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Remote answer"))),
			])
		(imports ?? store as? ImportingRecordLog)?.notifyImport()
		return turn
	}
}
