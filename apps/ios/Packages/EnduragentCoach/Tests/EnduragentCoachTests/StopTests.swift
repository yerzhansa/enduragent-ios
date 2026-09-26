import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct StopTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func aStoppedReplyNeverShowsAsQueuedAfterItStops() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Thursday is "), .hang]
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let stream = await coach.observe(.main)
		let watcher = Task { () -> [TurnState] in
			var seen: [TurnState] = []
			for await snapshot in stream {
				guard let state = snapshot.turns.first(where: { $0.id == turn })?.state else {
					continue
				}
				seen.append(state)
				if state.isSettled { break }
			}
			return seen
		}
		await coach.stop(.main)
		let seen = await watcher.value
		let afterStart = seen.drop { state in
			if case .processing = state { return false }
			return true
		}
		#expect(!afterStart.isEmpty)
		for state in afterStart {
			if case .accepted = state {
				Issue.record("the stopped reply went back to \(state) after it started")
			}
		}
		guard case .interrupted(let stopped)? = seen.last else {
			Issue.record("the observer never saw the stopped outcome: \(seen)")
			return
		}
		#expect(stopped.cause == .athleteStopped)
	}

	@Test func anObserverSeesTheStoppedReplyWhileStopWaitsOnTheStore() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 2)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("one"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		_ = try #require(try await coach.send(draft("two"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		let latest = LatestState()
		let stream = await coach.observe(.main)
		let watcher = Task {
			for await snapshot in stream {
				await latest.set(snapshot.turns.first { $0.id == running }?.state)
			}
		}
		async let stopped: Void = coach.stop(.main)
		var reached = store.reached.makeAsyncIterator()
		await reached.next()
		try await Task.sleep(for: .milliseconds(200))
		let seen = await latest.state
		store.release()
		await stopped
		watcher.cancel()
		guard case .interrupted(let first)? = seen else {
			Issue.record(
				"while Stop waited on the store, the observer last saw \(String(describing: seen))")
			return
		}
		#expect(first.cause == .athleteStopped)
	}

	@Test func aSendDuringStopStartsOnlyAfterTheStopFinishes() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 2)
		let host = ImmediateExecutionHost()
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
		transport.hangUntilCancelled = false
		transport.script = [.text("Three."), .finish(reason: .stop)]
		let third = try #require(try await coach.send(draft("three"), to: .main).acceptedTurn)
		try await Task.sleep(for: .milliseconds(200))
		#expect(transport.requests.isEmpty, "a send started while Stop was still settling")
		store.release()
		await stopped
		guard case .interrupted(let later)? = await coach.state(of: queued) else {
			Issue.record("the queued turn was not stopped")
			return
		}
		#expect(later.cause == .stoppedBeforeStart)
		let answered = try #require(await coach.settledState(of: third, in: .main))
		#expect(replyText(answered) == "Three.")
		#expect(transport.requests.count == 1)
		#expect(await host.ended(0)?.ending == .interrupted)
		#expect(
			await host.ended(1)?.ending == .finished(CompletionNotice(reply: "Three.", turn: third))
		)
	}

	@Test func stopSettlesATurnStillInTheWindowBeforeItStarts() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let host = ImmediateExecutionHost()
		let coach = makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)), host: host)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.stop(.main)
		guard case .interrupted(let stopped)? = await coach.state(of: turn) else {
			Issue.record("expected the collecting turn to be stopped")
			return
		}
		#expect(stopped.cause == .stoppedBeforeStart)
		#expect(
			stopped.notice
				== AthleteNotice(key: Catalog.chatTurnReceivedBeforeClose, action: .tryAgain(turn)))
		#expect(transport.requests.isEmpty)
		#expect(await host.ended(0)?.ending == .interrupted)
	}
}

actor LatestState {
	private(set) var state: TurnState?

	func set(_ next: TurnState?) {
		state = next
	}
}
