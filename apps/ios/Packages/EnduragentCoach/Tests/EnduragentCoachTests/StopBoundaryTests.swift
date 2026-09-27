import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct StopBoundaryTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	func interruption(of turn: TurnID, in coach: Coach) async -> InterruptionCause? {
		guard case .interrupted(let interrupted)? = await coach.state(of: turn) else { return nil }
		return interrupted.cause
	}

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
		#expect(await interruption(of: running, in: coach) == .athleteStopped)
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
		#expect(await interruption(of: running, in: coach) == .athleteStopped)
		#expect(await interruption(of: second, in: coach) == .stoppedBeforeStart)
		#expect(transport.requests.isEmpty)
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
		#expect(await interruption(of: running, in: coach) == .athleteStopped)
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
		#expect(await interruption(of: running, in: coach) == .athleteStopped)
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
