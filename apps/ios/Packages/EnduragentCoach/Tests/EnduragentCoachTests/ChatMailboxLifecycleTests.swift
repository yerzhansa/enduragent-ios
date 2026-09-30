import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension ChatMailboxTests {
	@Test func concurrentSendsOnOneChatCompleteInOrder() async throws {
		let transport = FakeModelTransport()
		transport.requestDelay = .milliseconds(40)
		transport.respond = ScriptedReply.sequence(
			[
				.text("first"),
				.finish(reason: .stop),
				.text("second"),
				.finish(reason: .stop),
			], otherwise: transport.respond)
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

	@Test func aTurnThatStartedNeverShowsAsWaitingAgain() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Still on."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		let states = Mutex<[TurnState]>([])
		let stream = await coach.observe(.main)
		let watching = Task {
			for await snapshot in stream {
				if let state = snapshot.turns.first?.state {
					states.withLock { $0.append(state) }
				}
			}
		}
		let turn = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "Still on.")
		watching.cancel()
		let seen = states.withLock { $0 }
		let started = try #require(
			seen.firstIndex { if case .processing = $0 { true } else { false } })
		let after = seen[started...].filter { if case .accepted = $0 { true } else { false } }
		#expect(after.isEmpty, "a started turn went back to waiting: \(seen)")
	}

	@Test func relaunchAfterExpiryMidReplyDoesNotRerunTheModel() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Yes, keep Thursday."), .hang], otherwise: transport.respond)
		let store = InMemoryRecordLog()
		let dying = FaultInjectingRecordLog(wrapping: store)
		let before = makeCoach(transport: transport, store: dying, clock: clock)
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.waitForLiveText(turn)
		try await waitForRecords(.deviceLocal([.replyObserved]), count: 1, in: store)
		try await before.dieWithoutWriting(to: dying)
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
		transport.respond = ScriptedReply.sequence(
			[.text("Still on."), .finish(reason: .stop)], otherwise: transport.respond)
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
		transport.respond = ScriptedReply.sequence(
			[.text("Still on."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)))
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.lifecycle(.enteredBackground)
		let settled = try #require(
			await coach.settledState(of: turn, in: .main, within: .seconds(5)))
		#expect(replyText(settled) == "Still on.")
	}

	@Test func enteringTheBackgroundWaitsBehindASendBeingAdmitted() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Joined."), .finish(reason: .stop)], otherwise: transport.respond)
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 2)
		let coach = makeCoach(
			transport: transport, store: store, clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)))
		let first = try #require(try await coach.send(draft("a"), to: .main).acceptedTurn)
		async let sent = coach.send(draft("b"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let backgrounded: Void = coach.lifecycle(.enteredBackground)
		try await Task.sleep(for: .milliseconds(100))
		store.release()
		await backgrounded
		let second = try #require(try await sent.acceptedTurn)
		let settled = try #require(
			await coach.settledState(of: first, in: .main, within: .seconds(5)))
		#expect(second == first, "the message being admitted missed the window it joined")
		#expect(replyText(settled) == "Joined.")
		#expect(await coach.transcript(.main) == ["a\nb", "Joined."])
	}

	@Test func willTerminateInterruptsTheRunningAttemptAndLeavesQueuedTurnsUnclaimed() async throws
	{
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is "), .hang], otherwise: transport.respond)
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

	@Test func willTerminateStartsNothingThatWasStillJoining() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Still on."), .finish(reason: .stop)], otherwise: transport.respond)
		let store = InMemoryRecordLog()
		let coach = makeCoach(
			transport: transport, store: store, clock: clock,
			coalescing: CoalescingPolicy(window: .milliseconds(200)))
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.lifecycle(.willTerminate)
		try await Task.sleep(for: .milliseconds(500))
		#expect(transport.requests.isEmpty)
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)
		).records
		#expect(claims.isEmpty)
		let reopened = makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn) == .accepted(.awaitingRestart))
	}
}
