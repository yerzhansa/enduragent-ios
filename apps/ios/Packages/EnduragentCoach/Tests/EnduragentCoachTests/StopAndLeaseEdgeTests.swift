import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct StopAndLeaseEdgeTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let saturdays: ScriptedEvent = .toolCall(
		name: "ledger_append",
		arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#)

	func settlements(of turn: TurnID, in store: any RecordLog) async throws -> [Settlement] {
		try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
			.compactMap { record in
				guard case .synced(.turnSettled(let body)) = record.body else { return nil }
				return body.settlement
			}
	}

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
		try await Task.sleep(for: .milliseconds(50))
		let terminated = Task { await coach.lifecycle(.willTerminate) }
		try await Task.sleep(for: .milliseconds(50))
		store.release()
		await stopped.value
		await expired.value
		await terminated.value
		let runningSettled = try await settlements(of: running, in: store)
		let queuedSettled = try await settlements(of: queued, in: store)
		#expect(runningSettled.count == 1)
		#expect(queuedSettled.count <= 1)
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
