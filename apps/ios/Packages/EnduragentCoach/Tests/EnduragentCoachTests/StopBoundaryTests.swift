import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct StopBoundaryTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func aSendAfterTheTapRunsWhileStopWaitsOnTheRunningReply() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		async let stopped: Void = coach.stop(.main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		transport.hangUntilCancelled = false
		transport.script = [.text("Three."), .finish(reason: .stop)]
		async let sent = coach.send(draft("three"), to: .main)
		try await Task.sleep(for: .milliseconds(150))
		store.release()
		await stopped
		let third = try #require(try await sent.acceptedTurn)
		let settled = try #require(
			await coach.settledState(of: third, in: .main, within: .seconds(5)))
		#expect(replyText(settled) == "Three.", "a send after the Stop tap was stopped: \(settled)")
		#expect(await coach.interruption(of: running) == .athleteStopped)
	}

	@Test func aSendMidAdmissionAtTheTapIsStoppedBeforeItStarts() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 2)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		async let sent = coach.send(draft("two"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let stopped: Void = coach.stop(.main)
		try await Task.sleep(for: .milliseconds(100))
		store.release()
		await stopped
		let second = try #require(try await sent.acceptedTurn)
		#expect(await coach.interruption(of: running) == .athleteStopped)
		#expect(await coach.interruption(of: second) == .stoppedBeforeStart)
		#expect(transport.requests.isEmpty)
	}

	@Test func aStopWhileTheOnlySendIsMidAdmissionStopsItBeforeItStarts() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Ran."), .finish(reason: .stop)]
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 1)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		async let sent = coach.send(draft("only"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let stopped: Void = coach.stop(.main)
		try await Task.sleep(for: .milliseconds(100))
		store.release()
		await stopped
		let turn = try #require(try await sent.acceptedTurn)
		#expect(await coach.interruption(of: turn) == .stoppedBeforeStart)
		try await Task.sleep(for: .milliseconds(100))
		#expect(transport.requests.isEmpty)
	}

	@Test func aTryAgainAfterTheTapRunsOnceTheStopSettles() async throws {
		let transport = FakeModelTransport()
		transport.script = Array(repeating: .fail(.http(status: 500)), count: 3)
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 2)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let failed = try #require(try await coach.send(draft("earlier"), to: .main).acceptedTurn)
		#expect(try #require(await coach.settledState(of: failed, in: .main)).retryable)
		transport.hangUntilCancelled = true
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		async let stopped: Void = coach.stop(.main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		transport.hangUntilCancelled = false
		transport.script = [.text("Recovered."), .finish(reason: .stop)]
		async let retried: Void = coach.retry(failed, in: .main)
		try await Task.sleep(for: .milliseconds(100))
		store.release()
		await stopped
		try await retried
		let answered = try await coach.waitForState(of: failed) { state in
			guard case .completed? = state else { return false }
			return true
		}
		#expect(answered.flatMap(replyText) == "Recovered.", "Try again after the tap: \(answered)")
		#expect(await coach.interruption(of: running) == .athleteStopped)
	}

	@Test func aTryAgainOfTheStoppedReplyWhileTheStopWaitsRunsAfterIt() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 2)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		async let sent = coach.send(draft("two"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let stopped: Void = coach.stop(.main)
		_ = try await coach.waitForState(of: running) { $0.map(isInterrupted) ?? false }
		transport.hangUntilCancelled = false
		transport.script = [.text("Again."), .finish(reason: .stop)]
		async let retried: Void = coach.retry(running, in: .main)
		try await Task.sleep(for: .milliseconds(100))
		store.release()
		await stopped
		try await retried
		let second = try #require(try await sent.acceptedTurn)
		let answered = try await coach.waitForState(of: running) { state in
			guard case .completed? = state else { return false }
			return true
		}
		#expect(answered.flatMap(replyText) == "Again.", "Try again during the Stop: \(answered)")
		#expect(await coach.interruption(of: second) == .stoppedBeforeStart)
	}

	@Test func aTryAgainMidAdmissionAtTheTapIsStoppedBeforeItStarts() async throws {
		let transport = FakeModelTransport()
		transport.script = Array(repeating: .fail(.http(status: 500)), count: 3)
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 2)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let failed = try #require(try await coach.send(draft("earlier"), to: .main).acceptedTurn)
		#expect(try #require(await coach.settledState(of: failed, in: .main)).retryable)
		transport.script = [.text("Should not run."), .finish(reason: .stop)]
		let before = transport.requests.count
		async let sent = coach.send(draft("two"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let retried: Void = coach.retry(failed, in: .main)
		try await Task.sleep(for: .milliseconds(100))
		async let stopped: Void = coach.stop(.main)
		try await Task.sleep(for: .milliseconds(100))
		store.release()
		await stopped
		try await retried
		let second = try #require(try await sent.acceptedTurn)
		try await Task.sleep(for: .milliseconds(300))
		#expect(await coach.interruption(of: second) == .stoppedBeforeStart)
		#expect(await coach.interruption(of: failed) == .stoppedBeforeStart)
		#expect(transport.requests.count == before)
	}

	@Test func anExpiryDuringAStopReturnsOnlyAfterTheStopSettles() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "userMessage", occurrence: 2)
		let host = KeepingHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		async let sent = coach.send(draft("two"), to: .main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let stopped: Void = coach.stop(.main)
		_ = try await coach.waitForState(of: running) { $0.map(isInterrupted) ?? false }
		let expiryReturned = Mutex(false)
		let expired = Task {
			await host.expire(lease: 0, .systemExpired)
			expiryReturned.withLock { $0 = true }
		}
		try await Task.sleep(for: .milliseconds(200))
		#expect(!expiryReturned.withLock { $0 }, "the expiry returned while the Stop still waited")
		store.release()
		await expired.value
		let second = try #require(try await sent.acceptedTurn)
		#expect(try await settlements(of: second, in: store).count == 1)
		await stopped
		#expect(await coach.interruption(of: running) == .athleteStopped)
		#expect(await coach.interruption(of: second) == .stoppedBeforeStart)
	}

	@Test func anExpiryDuringAStopJoinsItAndASendAfterTheTapStillRuns() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		let host = KeepingHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		async let stopped: Void = coach.stop(.main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		transport.hangUntilCancelled = false
		transport.script = [.text("Three."), .finish(reason: .stop)]
		async let sent = coach.send(draft("three"), to: .main)
		try await Task.sleep(for: .milliseconds(50))
		async let expired: Void = host.expire(lease: 0, .systemExpired)
		try await Task.sleep(for: .milliseconds(50))
		store.release()
		await stopped
		await expired
		let third = try #require(try await sent.acceptedTurn)
		let settled = try #require(
			await coach.settledState(of: third, in: .main, within: .seconds(5)))
		#expect(
			replyText(settled) == "Three.", "the send after the Stop tap was stopped: \(settled)")
		#expect(await coach.interruption(of: running) == .athleteStopped)
	}

	@Test func theFirstInterruptionNamesTheCause() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Yes, keep "), .hang]
		let store = HeldAppendLog(
			inner: InMemoryRecordLog(), holding: "replyObserved", occurrence: 1)
		let host = KeepingHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		async let stopped: Void = coach.stop(.main)
		try await Task.sleep(for: .milliseconds(50))
		async let expired: Void = host.expire(lease: 0, .systemExpired)
		try await Task.sleep(for: .milliseconds(50))
		store.release()
		await stopped
		await expired
		#expect(await coach.interruption(of: running) == .athleteStopped)
	}

	@Test func aTurnStillCollectingKeepsTheLeaseAfterAnEarlierTurnSettles() async throws {
		let transport = FakeModelTransport()
		transport.requestDelay = .milliseconds(200)
		transport.script = [
			.text("First."), .finish(reason: .stop), .text("Second."), .finish(reason: .stop),
		]
		let host = ImmediateExecutionHost()
		let coach = makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)), host: host)
		let first = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.lifecycle(.enteredBackground)
		await coach.waitUntilProcessing(first)
		let second = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: first, in: .main))
		try await Task.sleep(for: .milliseconds(100))
		#expect(host.leases.count == 1)
		#expect(host.leases.first?.ending == nil, "the lease ended while a turn was collecting")
		await coach.lifecycle(.enteredBackground)
		_ = try #require(await coach.settledState(of: second, in: .main))
		let lease = try #require(await host.ended(0))
		#expect(lease.ending == .finished(CompletionNotice(reply: "Second.", turn: second)))
		#expect(lease.progress?.settledTurns == 2)
		#expect(host.leases.count == 1)
	}
}
