import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ChatMailboxTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func concurrentSendsOnOneChatCompleteInOrder() async throws {
		let transport = FakeModelTransport()
		transport.requestDelay = .milliseconds(40)
		transport.script = [
			.text("first"),
			.finish(reason: .stop),
			.text("second"),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		let first = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(first)
		let second = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		#expect(first != second)
		#expect(replyText(try #require(await coach.settledState(of: first, in: .main))) == "first")
		#expect(
			replyText(try #require(await coach.settledState(of: second, in: .main))) == "second")
		#expect(await coach.transcript(.main) == ["one", "first", "two", "second"])
	}

	@Test func sendsInsideTheWindowJoinOneTurn() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("both"), .finish(reason: .stop)]
		let recording = BatchRecordingLog(inner: InMemoryRecordLog())
		let coach = makeCoach(
			transport: transport, store: recording, clock: clock,
			coalescing: CoalescingPolicy(window: .milliseconds(300)))
		let first = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		let second = try #require(
			try await coach.send(draft("And Friday?"), to: .main).acceptedTurn)
		#expect(first == second)
		#expect(recording.batches == [["userMessage"], ["userMessage"]])
		let settled = try #require(await coach.settledState(of: first, in: .main))
		#expect(replyText(settled) == "both")
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.map(\.athleteText) == ["Is Thursday on?\nAnd Friday?"])
		#expect(transport.requests.count == 1)
		#expect(transport.requests.first?.messages.last?.content.contains("And Friday?") == true)
	}

	@Test func cancellationSettlesInterruptedWithLiveText() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Thursday is "), .hang]
		let recording = BatchRecordingLog(inner: InMemoryRecordLog())
		let coach = makeCoach(transport: transport, store: recording, clock: clock)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		var sawText = false
		for await snapshot in await coach.observe(.main) {
			if case .processing(let processing)? = snapshot.turns.first?.state,
				!processing.liveText.isEmpty
			{
				sawText = true
				break
			}
		}
		#expect(sawText)
		await coach.stop(.main)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected interrupted, got \(settled)")
			return
		}
		#expect(interrupted.partial == "Thursday is ")
		#expect(interrupted.cause == .athleteStopped)
		#expect(interrupted.notice.action == .tryAgain(turn))
		#expect(
			recording.batches == [
				["userMessage"], ["turnClaim"], ["replyObserved"], ["turnSettled"],
			])
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.activity == .idle)
	}

	@Test func stopSettlesQueuedTurnsBeforeTheyStart() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		let first = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(first)
		let second = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		try await Task.sleep(for: .milliseconds(60))
		await coach.stop(.main)
		let firstState = try #require(await coach.settledState(of: first, in: .main))
		let secondState = try #require(await coach.settledState(of: second, in: .main))
		guard case .interrupted(let running) = firstState,
			case .interrupted(let queued) = secondState
		else {
			Issue.record("expected both interrupted, got \(firstState) and \(secondState)")
			return
		}
		#expect(running.cause == .athleteStopped)
		#expect(queued.cause == .stoppedBeforeStart)
		#expect(await coach.transcript(.main) == ["one", "two"])
	}

	@Test func stopInsideTheWindowSettlesTheTurnBeforeItStarts() async throws {
		let transport = FakeModelTransport()
		let recording = BatchRecordingLog(inner: InMemoryRecordLog())
		let coach = makeCoach(
			transport: transport, store: recording, clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)))
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.stop(.main)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		guard
			case .interrupted(let stopped)? = snapshot.turns.first(where: { $0.id == turn })?.state
		else {
			Issue.record("expected an interrupted turn, got \(snapshot.turns)")
			return
		}
		#expect(stopped.cause == .stoppedBeforeStart)
		#expect(stopped.notice.action == .tryAgain(turn))
		#expect(snapshot.activity == .idle)
		#expect(recording.batches == [["userMessage"], ["turnSettled"]])
		#expect(transport.requests.isEmpty)
	}

	@Test func aSlowFirstReadKeepsAMessageSavedWhileItRead() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let inner = InMemoryRecordLog()
		let store = SlowConversationReadLog(inner: inner, delay: .milliseconds(500))
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		async let observed = coach.currentSnapshot(.main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		let turn = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		_ = await observed
		let settled = try #require(
			await coach.settledState(of: turn, in: .main, within: .seconds(5)))
		#expect(replyText(settled) == "Still on.")
		#expect(try #require(await coach.currentSnapshot(.main)).turns.map(\.id) == [turn])
		let saved = try await inner.fetch(
			RecordQuery(scope: .synced([.turnSettled]), chatId: .main))
		#expect(saved.records.count == 1)
		#expect(transport.requests.count == 1)
	}

	@Test func aFailedFirstReadWipesNothingSavedAfterIt() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let inner = InMemoryRecordLog()
		let store = SlowConversationReadLog(inner: inner, delay: .milliseconds(500), fails: true)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		async let observed = coach.currentSnapshot(.main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		let sent = draft("Is Thursday on?")
		let first: SendOutcome?
		do {
			first = try await coach.send(sent, to: .main)
		} catch {
			#expect(error == .storageUnavailable)
			first = nil
		}
		_ = await observed
		let outcome = try await coach.send(sent, to: .main)
		let turn = try #require(outcome.acceptedTurn)
		if let first {
			#expect(first == outcome)
		}
		let settled = try #require(
			await coach.settledState(of: turn, in: .main, within: .seconds(5)))
		#expect(replyText(settled) == "Still on.")
		#expect(try #require(await coach.currentSnapshot(.main)).turns.map(\.id) == [turn])
		let saved = try await inner.fetch(
			RecordQuery(scope: .synced([.userMessage]), chatId: .main))
		#expect(saved.records.count == 1)
	}

	@Test func stopCancelsTheRunningReplyWhileASendWaitsOnTheStore() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 2)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		async let second = coach.send(draft("two"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let stopped: Void = coach.stop(.main)
		let interrupted = await coach.settledState(of: running, in: .main, within: .seconds(3))
		store.release()
		await stopped
		let queued = try #require(try await second.acceptedTurn)
		guard case .interrupted(let first)? = interrupted else {
			Issue.record(
				"the running reply did not stop while the send waited: \(String(describing: interrupted))"
			)
			return
		}
		#expect(first.cause == .athleteStopped)
		guard case .interrupted(let later)? = await coach.settledState(of: queued, in: .main) else {
			Issue.record("the waiting send was not stopped")
			return
		}
		#expect(later.cause == .stoppedBeforeStart)
	}

	@Test func retryOfAwaitingRestartTurnClaimsUnderNewAttempt() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let store = InMemoryRecordLog()
		let recording = BatchRecordingLog(inner: store)
		let before = makeCoach(
			transport: transport, store: recording, clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)))
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)

		let reopened = makeCoach(transport: transport, store: recording, clock: clock)
		#expect(
			try #require(await reopened.currentSnapshot(.main)).turns.first?.state
				== .accepted(.awaitingRestart))
		try await reopened.retry(turn, in: .main)
		let settled = try #require(await reopened.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "Still on.")
		#expect(
			recording.batches == [
				["userMessage"], ["turnClaim"], ["replyObserved"], ["turnSettled"],
			])
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)
		)
		.records
		let settlements = try await store.fetch(
			RecordQuery(scope: .synced([.turnSettled]), turn: turn)
		).records
		#expect(claims.count == 1)
		#expect(settlements.count == 1)
		guard case .deviceLocal(.turnClaim(let claim))? = claims.first?.body,
			case .synced(.turnSettled(let settledBody))? = settlements.first?.body
		else {
			Issue.record("expected a claim and a settlement")
			return
		}
		#expect(claim.attempt == settledBody.attempt)
		#expect(claims.first?.cause == .operation(.turn(turn), claim.attempt))
		#expect(await reopened.transcript(.main) == ["Thursday?", "Still on."])
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await reopened.retry(turn, in: .main)
		}
	}

	@Test func retryOfAFailedTurnMintsASecondAttempt() async throws {
		let transport = FakeModelTransport()
		transport.script =
			Array(repeating: .fail(.http(status: 500)), count: 3)
			+ [.text("Recovered."), .finish(reason: .stop)]
		let store = InMemoryRecordLog()
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		let failed = try #require(await coach.settledState(of: turn, in: .main))
		#expect(failure(failed) == .model(.providerDown(.outage)))
		#expect(failed.retryable)
		try await coach.retry(turn, in: .main)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "Recovered.")
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)
		)
		.records
		#expect(claims.count == 2)
		#expect(await coach.transcript(.main) == ["Thursday?", "Recovered."])
	}

	@Test func aSecondTryAgainWhileTheFirstStartsIsRefused() async throws {
		let transport = FakeModelTransport()
		transport.script = Array(repeating: .fail(.http(status: 500)), count: 3)
		let store = InMemoryRecordLog()
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		transport.script = Array(repeating: .fail(.http(status: 500)), count: 6)
		async let first = refusal { () async throws(RetryRefusal) in
			try await coach.retry(turn, in: .main)
		}
		async let second = refusal { () async throws(RetryRefusal) in
			try await coach.retry(turn, in: .main)
		}
		let refusals = await [first, second]
		#expect(refusals.compactMap { $0 } == [.alreadyRunning])
		await coach.waitForMemoryFlush()
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)
		)
		.records
		#expect(claims.count == 2)
	}

	@Test func retryOfAnUnknownTurnIsRefused() async throws {
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), clock: clock)
		await #expect(throws: RetryRefusal.unknownTurn) {
			try await coach.retry(TurnID(ulid: fixedUlid(7)), in: .main)
		}
	}

	@Test func confirmDoesNotEnterTheMailbox() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		_ = try await coach.send(draft("hang"), to: .main)
		for await snapshot in await coach.observe(.main) {
			if case .processing? = snapshot.turns.first?.state { break }
		}
		let outcome = try await coach.confirm(chatId: .main, nonce: Nonce())
		#expect(outcome == .none)
		await coach.stop(.main)
	}
}
