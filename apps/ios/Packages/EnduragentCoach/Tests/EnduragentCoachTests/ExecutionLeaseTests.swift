import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ExecutionLeaseTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let host = ImmediateExecutionHost()
	let athleteLease = LeaseRequest(
		chat: .main, initiatedBy: .athlete, title: Catalog.chatNoticeWorking,
		language: .en)
	let saturdays: ScriptedEvent = .toolCall(
		name: "ledger_append",
		arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#)
	let schedule: ScriptedEvent = .toolCall(
		name: "memory_write",
		arguments:
			#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#)

	func coach(host: (any ExecutionHost)? = nil) -> Coach {
		makeCoach(transport: transport, store: store, clock: clock, host: host ?? self.host)
	}

	func settlements(of turn: TurnID) async throws -> [Settlement] {
		try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
			.compactMap { record in
				guard case .synced(.turnSettled(let body)) = record.body else { return nil }
				return body.settlement
			}
	}

	func claims(of turn: TurnID) async throws -> [TurnClaimBody] {
		try await store.fetch(RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)).records
			.compactMap { record in
				guard case .deviceLocal(.turnClaim(let body)) = record.body else { return nil }
				return body
			}
	}

	@Test func oneLeasePerDrainCoversQueuedTurnAndFlush() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.requestDelay = .milliseconds(500)
		transport.script = [
			.text("First."), .finish(reason: .stop), .text("Second."), .finish(reason: .stop),
		]
		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		let coach = coach()
		let first = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(first)
		let second = try #require(
			try await coach.send(draft("And Sundays?"), to: .main).acceptedTurn)
		let lease = try #require(await host.ended(0, within: .seconds(20)))
		#expect(host.leases.count == 1)
		#expect(lease.request == athleteLease)
		#expect(lease.kind == .continuedProcessing)
		#expect(
			lease.ending
				== .finished(CompletionNotice(reply: "Second.", turn: second, language: .en)))
		#expect(lease.progress?.settledTurns == 2)
		#expect(lease.progress?.totalTurns == 2)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records.count
				== 1)
		#expect(sent(.chatAttempt, by: transport).count == 2)
		#expect(sent(.memoryFlush, by: transport).count == 2)
		#expect(replyText(try #require(await coach.state(of: first))) == "First.")
		#expect(try await claims(of: second).map(\.lease) == [.continuedProcessing])
	}

	@Test func theLeaseBeginsAtSendWhileTheWindowIsStillOpen() async throws {
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let coach = makeCoach(
			transport: transport, store: store, clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)), host: host)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		let deadline = ContinuousClock.now + .seconds(2)
		while host.leases.isEmpty, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(host.leases.map(\.request) == [athleteLease])
		#expect(
			await coach.state(of: turn)
				== .accepted(.collecting(until: clock.now.addingTimeInterval(60))))
		await coach.stop(.main)
	}

	@Test func expiryMidReplySettlesInterruptedWithPartialText() async throws {
		transport.script = [.text("Yes, keep Thursday."), .hang]
		let coach = coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let started = ContinuousClock.now
		await host.expire(.systemExpired)
		let took = ContinuousClock.now - started
		let state = try #require(await coach.state(of: turn))
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.partial == "Yes, keep Thursday.")
		#expect(interrupted.cause == .systemExpired)
		#expect(
			interrupted.notice
				== AthleteNotice(
					key: Catalog.chatTurnInterruptedNothingChanged, action: .tryAgain(turn)))
		#expect(took < .milliseconds(500), "expiry to settlement took \(took)")
		#expect(
			try await settlements(of: turn) == [
				.interrupted(partial: "Yes, keep Thursday.", cause: .systemExpired, saved: .none)
			])
		let lease = try #require(await host.ended(0))
		#expect(lease.expiry == .systemExpired)
		#expect(lease.ending == .interrupted)
		let reopened = makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn) == state)
		#expect(transport.requests.count == 1)
	}

	@Test func expiryCancelsQueuedTurnsAsStoppedBeforeStart() async throws {
		transport.hangUntilCancelled = true
		let coach = coach()
		let first = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(first)
		let second = try #require(try await coach.send(draft("Friday?"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		await host.expire(.systemExpired)
		guard case .interrupted(let running)? = await coach.state(of: first),
			case .interrupted(let queued)? = await coach.state(of: second)
		else {
			Issue.record("expected both turns interrupted")
			return
		}
		#expect(running.cause == .systemExpired)
		#expect(queued.cause == .stoppedBeforeStart)
		#expect(
			queued.notice
				== AthleteNotice(
					key: Catalog.chatTurnInterruptedNothingChanged, action: .tryAgain(second)))
		#expect(try await claims(of: second).isEmpty)
		#expect(await host.ended(0)?.ending == .interrupted)
		#expect(try #require(await coach.currentSnapshot(.main)).activity == .idle)
	}

	@Test func leaseEndsFinishedWithNoticeWhenReplyLands() async throws {
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let coach = coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		#expect(
			replyText(try #require(await coach.settledState(of: turn, in: .main))) == "Still on.")
		let lease = try #require(await host.ended(0))
		#expect(
			lease.ending
				== .finished(CompletionNotice(reply: "Still on.", turn: turn, language: .en)))
		#expect(
			lease.ending
				== .finished(CompletionNotice(reply: "  Still on.\n", turn: turn, language: .en)))
		#expect(
			lease.progress
				== LeaseProgress(settledTurns: 1, totalTurns: 1, step: 1, stepLimit: 10))
		#expect(lease.expiry == nil)
		#expect(try await claims(of: turn).map(\.lease) == [.continuedProcessing])
		#expect(host.leases.count == 1)
	}

	@Test func progressReportsTheRealStepOfAToolTurn() async throws {
		transport.script = [
			saturdays, .finish(reason: .toolCalls), .text("Noted."), .finish(reason: .stop),
		]
		let coach = coach()
		_ = try await coach.sendAndSettle("Remember Saturdays")
		let lease = try #require(await host.ended(0))
		#expect(
			lease.progress
				== LeaseProgress(settledTurns: 1, totalTurns: 1, step: 2, stepLimit: 10))
	}

	@Test func expiryAfterAMemorySaveOffersNoTryAgain() async throws {
		transport.script = [schedule, .finish(reason: .toolCalls), .hang]
		let coach = coach()
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		try await waitForRecords(.synced([.memorySection]), count: 1, in: store)
		await host.expire(.systemExpired)
		let state = try #require(await coach.state(of: turn))
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .systemExpired)
		#expect(!interrupted.saved.isEmpty)
		#expect(
			interrupted.notice
				== AthleteNotice(key: Catalog.chatTurnInterruptedSomeSaved, action: nil))
		#expect(!state.retryable)
	}

	@Test func graceEndedSettlesTheRunningTurnAsGraceEnded() async throws {
		transport.hangUntilCancelled = true
		let coach = coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(turn)
		await host.expire(.graceEnded)
		guard case .interrupted(let interrupted)? = await coach.state(of: turn) else {
			Issue.record("expected interrupted")
			return
		}
		#expect(interrupted.cause == .graceEnded)
		#expect(interrupted.notice.action == .tryAgain(turn))
	}

	@Test func aReplyThatLandsWhileAwayIsMarkedCompletedInBackground() async throws {
		transport.requestDelay = .milliseconds(200)
		transport.script = [
			.text("Still on."), .finish(reason: .stop), .text("Yes."), .finish(reason: .stop),
		]
		let coach = coach()
		let away = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(away)
		await coach.lifecycle(.enteredBackground)
		_ = try #require(await coach.settledState(of: away, in: .main))
		await coach.lifecycle(.becameActive)
		let here = try #require(try await coach.send(draft("Friday?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: here, in: .main))
		let turns = try #require(await coach.currentSnapshot(.main)).turns
		#expect(turns.map(\.completedInBackground) == [true, false])
	}

	@Test func aFailedReplyWhileAwayIsNotMarkedCompleted() async throws {
		transport.requestDelay = .milliseconds(200)
		transport.script = [.fail(.http(status: 401))]
		let coach = coach()
		let away = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(away)
		await coach.lifecycle(.enteredBackground)
		_ = try #require(await coach.settledState(of: away, in: .main))
		#expect(
			try #require(await coach.currentSnapshot(.main)).turns.first?.completedInBackground
				== false)
		#expect(await host.ended(0)?.ending == .finished(nil))
	}

	@Test func aLateExpiryFromAnEndedLeaseStopsNothing() async throws {
		let keeping = KeepingHost()
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let coach = coach(host: keeping)
		_ = try await coach.sendAndSettle("Thursday?")
		transport.hangUntilCancelled = true
		let running = try #require(try await coach.send(draft("Friday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(running)
		await keeping.expire(lease: 0, .systemExpired)
		try await Task.sleep(for: .milliseconds(100))
		guard case .processing? = await coach.state(of: running) else {
			Issue.record("an ended lease's expiry stopped the next lease's turn")
			return
		}
		await keeping.expire(lease: 1, .systemExpired)
		guard case .interrupted(let interrupted)? = await coach.state(of: running) else {
			Issue.record("the current lease's expiry did not stop its turn")
			return
		}
		#expect(interrupted.cause == .systemExpired)
	}

	@Test func recoveryDrainsFlushJobsUnderAGracePeriodLease() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		try await seedPendingJob(covering: history[0])
		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		let coach = coach()
		await coach.lifecycle(.becameActive)
		let lease = try #require(await host.ended(0))
		#expect(lease.request.initiatedBy == .recovery)
		#expect(lease.kind == .gracePeriodOnly)
		#expect(lease.ending == .finished(nil))
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records.count
				== 1)
	}

	@Test func aSendDuringRecoveryMovesTheDrainToAnAthleteLease() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		try await seedPendingJob(covering: history[0])
		transport.requestDelay = .milliseconds(300)
		transport.flushScript = [.finish(reason: .stop)]
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let coach = coach()
		await coach.lifecycle(.becameActive)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		let recovery = try #require(await host.ended(0))
		#expect(recovery.request.initiatedBy == .recovery)
		#expect(recovery.ending == .finished(nil))
		let athlete = try #require(await host.ended(1, within: .seconds(10)))
		#expect(athlete.request == athleteLease)
		#expect(
			athlete.ending
				== .finished(CompletionNotice(reply: "Still on.", turn: turn, language: .en)))
		#expect(try await claims(of: turn).map(\.lease) == [.continuedProcessing])
	}

	@Test func aClaimRecordsTheLeaseKindTheHostGranted() async throws {
		transport.script = [.text("Still on."), .finish(reason: .stop)]
		let coach = coach(host: GraceOnlyHost())
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		#expect(try await claims(of: turn).map(\.lease) == [.gracePeriodOnly])
	}

	@Test func recordsDebugNamesTheClaimLeaseAndTheExpiry() async throws {
		transport.script = [.text("Yes, keep "), .hang]
		let coach = coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		await host.expire(.systemExpired)
		let rows = try await coach.recordSyncProbe().snapshot().rows
		#expect(rows.filter { $0.kind == "turnClaim" }.map(\.detail) == ["continuedProcessing"])
		#expect(
			rows.filter { $0.kind == "turnSettled" }.map(\.detail) == ["interrupted systemExpired"])
	}

	@Test func aTimedExpiryInterruptsTheRunningTurnWithoutATap() async throws {
		transport.script = [.text("Yes, keep "), .hang]
		let expiryClock = HeldClock()
		let timed = ImmediateExecutionHost(expiringAfter: .milliseconds(300), clock: expiryClock)
		let coach = coach(host: timed)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		try await expiryClock.waitUntilHeld(.milliseconds(300))
		expiryClock.release(.milliseconds(300))
		guard
			case .interrupted(let interrupted)? = await coach.settledState(
				of: turn, in: .main, within: .seconds(5))
		else {
			Issue.record("the timed expiry did not interrupt the turn")
			return
		}
		#expect(interrupted.cause == .systemExpired)
		#expect(interrupted.partial == "Yes, keep ")
		#expect(timed.leases.first?.expiry == .systemExpired)
	}

	@Test func expiryStartsNoFlushAfterTheInterruptedTurn() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.script = [.text("Noted, "), .hang]
		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		let coach = coach()
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		try await waitForRecords(.deviceLocal([.flushPending]), count: 1, in: store)
		await host.expire(.systemExpired)
		try await Task.sleep(for: .milliseconds(200))
		#expect(sent(.memoryFlush, by: transport).isEmpty)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records.isEmpty
		)
		#expect(host.leases.count == 1)
	}

	private func seedPendingJob(covering turn: SeededTurn) async throws {
		let at = clock.now.addingTimeInterval(-5)
		try await seed(
			store,
			[
				seededRecord(
					store, at: at, ulid: ULID.generate(at: at),
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, trigger: .softThreshold,
								messageUlids: [turn.user, turn.reply]))))
			])
	}
}
