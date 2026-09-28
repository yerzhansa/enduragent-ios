import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct StopAndLeaseEdgeTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let saturdays: ScriptedEvent = .toolCall(
		name: "ledger_append",
		arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#)

	@Test func stopExpiryAndTerminateTogetherSettleEachTurnOnce() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		let host = KeepingHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		let queued = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		let stopped = Task { await coach.stop(.main) }
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		let expired = Task { await host.expire(lease: 0, .systemExpired) }
		try await Task.sleep(for: .milliseconds(200))
		let terminated = Task { await coach.lifecycle(.willTerminate) }
		try await Task.sleep(for: .milliseconds(200))
		store.release()
		await stopped.value
		await expired.value
		await terminated.value
		let runningSettled = try await settlements(of: running, in: store)
		let queuedSettled = try await settlements(of: queued, in: store)
		#expect(runningSettled.count == 1)
		#expect(queuedSettled.count == 1)
		#expect(await coach.interruption(of: queued) == .stoppedBeforeStart)
	}

	@Test func anExpiryDuringAStopSettlesTheQueuedTurnExactlyOnce() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		let host = KeepingHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		let queued = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		async let stopped: Void = coach.stop(.main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let expired: Void = host.expire(lease: 0, .systemExpired)
		try await Task.sleep(for: .milliseconds(200))
		store.release()
		await stopped
		await expired
		#expect(try await settlements(of: queued, in: store).count == 1)
		#expect(await coach.interruption(of: queued) == .stoppedBeforeStart)
		#expect(await coach.interruption(of: running) == .athleteStopped)
	}

	@Test func willTerminateDuringAStopReturnsWithoutWaitingOnAdmission() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 3)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		let queued = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		async let sent = coach.send(draft("three"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let stopped: Void = coach.stop(.main)
		_ = try await coach.waitForState(of: running) { $0.map(isInterrupted) ?? false }
		let terminated = Mutex(false)
		let terminating = Task {
			await coach.lifecycle(.willTerminate)
			terminated.withLock { $0 = true }
		}
		try await waitUntil(within: .seconds(2)) { terminated.withLock { $0 } }
		#expect(await coach.currentSnapshot(.main)?.activity == .stopping)
		store.release()
		await stopped
		await terminating.value
		let third = try #require(try await sent.acceptedTurn)
		#expect(await coach.interruption(of: running) == .athleteStopped)
		for turn in [queued, third] {
			#expect(await coach.interruption(of: turn) == .stoppedBeforeStart)
			#expect(try await settlements(of: turn, in: store).count == 1)
			#expect(try await claims(of: turn, in: store).isEmpty)
		}
	}

	@Test func willTerminateEndsTheLeaseAsInterrupted() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let host = ImmediateExecutionHost()
		let coach = makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		await coach.lifecycle(.willTerminate)
		#expect(await host.ended(0)?.ending == .interrupted)
		#expect(host.leases.count == 1)
	}

	@Test func willTerminateBeginsNoLeaseForASendThatLandsAfterIt() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Ran."), .finish(reason: .stop)]
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 1)
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		async let sent = coach.send(draft("only"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		await coach.lifecycle(.willTerminate)
		store.release()
		let turn = try #require(try await sent.acceptedTurn)
		try await Task.sleep(for: .milliseconds(300))
		#expect(host.leases.isEmpty, "a lease began after willTerminate: \(host.leases)")
		#expect(try await claims(of: turn, in: store).isEmpty)
		#expect(transport.requests.isEmpty)
		let reopened = makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn) == .accepted(.awaitingRestart))
	}

	@Test func terminationDuringInitialRecoveryPreventsLaterLeaseAndClaim() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Ran."), .finish(reason: .stop)]
		let store = HeldFirstReadLog(inner: InMemoryRecordLog())
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		async let sent = coach.send(draft("first send"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		await coach.lifecycle(.willTerminate)
		store.release()
		let turn = try #require(try await sent.acceptedTurn)
		_ = await coach.settledState(of: turn, in: .main, within: .seconds(1))
		#expect(host.leases.isEmpty, "a lease began after willTerminate: \(host.leases)")
		#expect(try await claims(of: turn, in: store).isEmpty)
		#expect(transport.requests.isEmpty)
		let reopened = makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn) == .accepted(.awaitingRestart))
	}

	@Test func willTerminateDoesNotWaitOnTheFlushQueueAfterTheStoppedTurn() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldFlushReadLog(inner: InMemoryRecordLog())
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		store.holdNextChatFlushRead()
		let terminated = Mutex(false)
		let terminating = Task {
			await coach.lifecycle(.willTerminate)
			terminated.withLock { $0 = true }
		}
		try await waitUntil(within: .seconds(2)) { terminated.withLock { $0 } }
		store.release()
		await terminating.value
		#expect(await coach.interruption(of: running) == .appTerminating)
	}

	@Test func anExpiryDuringTerminationJoinsItAndLeavesQueuedTurnsUnclaimed() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		let host = KeepingHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		let queued = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		async let terminated: Void = coach.lifecycle(.willTerminate)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let expired: Void = host.expire(lease: 0, .systemExpired)
		try await Task.sleep(for: .milliseconds(200))
		store.release()
		await terminated
		await expired
		#expect(await coach.interruption(of: running) == .appTerminating)
		#expect(try await settlements(of: queued, in: store).isEmpty)
		#expect(try await claims(of: queued, in: store).isEmpty)
	}

	@Test func aFailedTurnEndsItsLeaseWithNoNotice() async throws {
		let transport = FakeModelTransport()
		transport.script = [.fail(.http(status: 401))]
		let store = InMemoryRecordLog()
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let turn = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		let lease = await host.ended(0)
		#expect(lease?.ending == .finished(nil))
		#expect(host.leases.count == 1)
	}

	@Test func aSendAfterAStopBeginsANewLease() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = InMemoryRecordLog()
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		_ = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		await coach.stop(.main)
		#expect(await host.ended(0)?.ending == .interrupted)
		#expect(host.leases.count == 1)
		transport.hangUntilCancelled = false
		transport.script = [.text("Three."), .finish(reason: .stop)]
		let third = try #require(try await coach.send(draft("three"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: third, in: .main))
		#expect(
			await host.ended(1)?.ending == .finished(CompletionNotice(reply: "Three.", turn: third))
		)
		#expect(host.leases.count == 2)
	}

	@Test func aFlushJobDroppedByStopDrainsOnceAtTheNextSettlement() async throws {
		let store = InMemoryRecordLog()
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		let transport = FakeModelTransport()
		transport.requestDelay = .milliseconds(300)
		transport.script = [.text("First."), .finish(reason: .stop), .hang]
		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let first = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(first)
		let second = try #require(
			try await coach.send(draft("And Sundays?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: first, in: .main))
		await coach.waitUntilProcessing(second)
		let pendingBeforeStop = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.flushPending]))
		).records.count
		#expect(pendingBeforeStop == 1)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records
				.isEmpty)
		await coach.stop(.main)
		try await Task.sleep(for: .milliseconds(300))
		#expect(sent(.memoryFlush, by: transport).isEmpty)
		transport.requestDelay = nil
		transport.script = [.text("Third."), .finish(reason: .stop)]
		let third = try #require(try await coach.send(draft("Third?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: third, in: .main))
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		try await Task.sleep(for: .milliseconds(300))
		let settledAfter = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.flushSettled]))
		).records.count
		#expect(settledAfter == pendingBeforeStop)
		#expect(sent(.memoryFlush, by: transport).count == 2 * pendingBeforeStop)
	}

	@Test func aFlushJobDroppedByStopDrainsOnceAtTheNextLaunch() async throws {
		let store = InMemoryRecordLog()
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		let transport = FakeModelTransport()
		transport.requestDelay = .milliseconds(300)
		transport.script = [.text("First."), .finish(reason: .stop), .hang]
		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let first = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(first)
		let second = try #require(
			try await coach.send(draft("And Sundays?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: first, in: .main))
		await coach.waitUntilProcessing(second)
		await coach.stop(.main)
		#expect(sent(.memoryFlush, by: transport).isEmpty)
		let transport2 = FakeModelTransport()
		transport2.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		let host2 = ImmediateExecutionHost()
		let relaunched = makeCoach(transport: transport2, store: store, clock: clock, host: host2)
		await relaunched.lifecycle(.becameActive)
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		try await Task.sleep(for: .milliseconds(300))
		#expect(sent(.memoryFlush, by: transport2).count == 2)
	}

	@Test func anExpiredTurnIsNotSettledAgainAtTheNextLaunch() async throws {
		let store = InMemoryRecordLog()
		let transport = FakeModelTransport()
		transport.script = [.text("Yes, keep "), .hang]
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		await host.expire(.systemExpired)
		let relaunched = makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		await relaunched.lifecycle(.becameActive)
		try await Task.sleep(for: .milliseconds(300))
		let all = try await settlements(of: turn, in: store)
		#expect(all.count == 1)
		guard case .interrupted(let state)? = await relaunched.state(of: turn) else {
			Issue.record("not interrupted after relaunch")
			return
		}
		#expect(state.cause == .systemExpired)
		#expect(state.notice.action == .tryAgain(turn))
	}
}
