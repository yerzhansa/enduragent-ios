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

	@Test func relaunchAfterExpiryMidReplyDoesNotRerunTheModel() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Yes, keep Thursday."), .hang]
		let store = InMemoryRecordLog()
		let dying = FaultInjectingRecordLog(wrapping: store)
		let before = makeCoach(transport: transport, store: dying, clock: clock)
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.waitForLiveText(turn)
		try await waitForRecords(.deviceLocal([.replyObserved]), count: 1, in: store)
		await before.dieWithoutWriting(to: dying)
		let reopened = makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		try await Task.sleep(for: .milliseconds(100))
		#expect(transport.requests.count == 1)
		let state = try #require(await reopened.state(of: turn))
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .processEnded)
		#expect(interrupted.partial.isEmpty)
		#expect(await reopened.transcript(.main) == ["Thursday?"])
		#expect(transport.requests.count == 1)
	}

	@Test func retryOfRepliedTurnIsRefusedAlreadyAnswered() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let store = InMemoryRecordLog()
		let before = makeCoach(transport: transport, store: store, clock: clock)
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		_ = try #require(await before.settledState(of: turn, in: .main))
		let reopened = makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await reopened.retry(turn, in: .main)
		}
		#expect(transport.requests.count == 1)
		#expect(await reopened.transcript(.main) == ["Thursday?", "Still on."])
	}

	@Test func enteredBackgroundClosesTheCoalescingWindow() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let coach = makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)))
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.lifecycle(.enteredBackground)
		let settled = try #require(
			await coach.settledState(of: turn, in: .main, within: .seconds(5)))
		#expect(replyText(settled) == "Still on.")
	}

	@Test func willTerminateInterruptsTheRunningAttemptAndLeavesQueuedTurnsUnclaimed() async throws
	{
		let transport = FakeModelTransport()
		transport.script = [.text("Thursday is "), .hang]
		let store = InMemoryRecordLog()
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let first = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(first)
		let second = try #require(try await coach.send(draft("Friday?"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		await coach.lifecycle(.willTerminate)
		let running = try #require(await coach.state(of: first))
		guard case .interrupted(let interrupted) = running else {
			Issue.record("expected interrupted, got \(running)")
			return
		}
		#expect(interrupted.cause == .appTerminating)
		#expect(interrupted.partial == "Thursday is ")
		#expect(
			interrupted.notice
				== AthleteNotice(
					key: Catalog.chatTurnInterruptedNothingChanged, action: .tryAgain(first)))
		try await Task.sleep(for: .milliseconds(100))
		#expect(transport.requests.count == 1)
		let secondClaims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: second)
		).records
		#expect(secondClaims.isEmpty)
		let reopened = makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: second) == .accepted(.awaitingRestart))
		#expect(await reopened.state(of: first) == running)
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
