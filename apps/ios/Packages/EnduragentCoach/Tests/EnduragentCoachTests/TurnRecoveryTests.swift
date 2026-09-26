import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnRecoveryTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let memorySaved = WriteSummary(
		memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)

	func processBeforeTheKill(coalescing: CoalescingPolicy = quickWindow) -> (
		Coach, FaultInjectingRecordLog
	) {
		let dying = FaultInjectingRecordLog(wrapping: store)
		return (
			makeCoach(transport: transport, store: dying, clock: clock, coalescing: coalescing),
			dying
		)
	}

	func relaunched(over log: (any RecordLog)? = nil) async -> Coach {
		let coach = makeCoach(transport: transport, store: log ?? store, clock: clock)
		await coach.lifecycle(.becameActive)
		return coach
	}

	func settlements(of turn: TurnID) async throws -> [AthleteRecord] {
		try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
	}

	func claims(of turn: TurnID) async throws -> [AthleteRecord] {
		try await store.fetch(RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)).records
	}

	@Test func deadClaimIsInterruptedWithProcessEndedAndStampedWrites() async throws {
		transport.script = [
			.toolCall(
				name: "memory_write",
				arguments:
					#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
			),
			.finish(reason: .toolCalls),
			.hang,
		]
		let (before, dying) = processBeforeTheKill()
		let turn = try #require(
			try await before.send(draft("Remember my Saturday ride"), to: .main).acceptedTurn)
		try await waitForRecords(.synced([.memorySection]), count: 1, in: store)
		await before.dieWithoutWriting(to: dying)
		let after = await relaunched()
		let state = try #require(await after.state(of: turn))
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .processEnded)
		#expect(interrupted.partial.isEmpty)
		#expect(interrupted.saved == memorySaved)
		#expect(
			interrupted.notice
				== AthleteNotice(key: Catalog.chatTurnInterruptedSomeSaved, action: nil))
		#expect(!state.retryable)
		let claim = try #require(try await claims(of: turn).first)
		guard case .deviceLocal(.turnClaim(let claimed)) = claim.body else {
			Issue.record("expected a claim, got \(claim.body)")
			return
		}
		let settled = try await settlements(of: turn)
		#expect(
			settled.map(\.body) == [
				.synced(
					.turnSettled(
						TurnSettledBody(
							chatId: .main, turn: turn, attempt: claimed.attempt,
							settlement: .interrupted(
								partial: "", cause: .processEnded, saved: memorySaved))))
			])
		#expect(settled.first?.cause == claim.cause)
	}

	@Test func claimedThenKilledTurnIsInterruptedAndTryAgainAnswersIt() async throws {
		transport.hangUntilCancelled = true
		let (before, dying) = processBeforeTheKill()
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.waitUntilProcessing(turn)
		await before.dieWithoutWriting(to: dying)
		transport.hangUntilCancelled = false
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		let after = await relaunched()
		let state = try #require(await after.state(of: turn))
		#expect(state != .accepted(.awaitingRestart))
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .processEnded)
		#expect(interrupted.saved == .none)
		#expect(
			interrupted.notice
				== AthleteNotice(
					key: Catalog.chatTurnInterruptedNothingChanged, action: .tryAgain(turn)))
		#expect(state.retryable)
		try await after.retry(turn, in: .main)
		let replied = try #require(await after.settledState(of: turn, in: .main))
		#expect(replyText(replied) == "Thursday is on.")
		#expect(try await claims(of: turn).count == 2)
		#expect(try await settlements(of: turn).count == 2)
		#expect(await after.transcript(.main) == ["Thursday?", "Thursday is on."])
	}

	@Test func theFirstSnapshotAfterRelaunchAlreadyShowsTheRecoveredTurn() async throws {
		transport.hangUntilCancelled = true
		let (before, dying) = processBeforeTheKill()
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.waitUntilProcessing(turn)
		await before.dieWithoutWriting(to: dying)
		let after = makeCoach(transport: transport, store: store, clock: clock)
		let first = try #require(await after.currentSnapshot(.main)?.turns.first?.state)
		guard case .interrupted(let interrupted) = first else {
			Issue.record("expected interrupted, got \(first)")
			return
		}
		#expect(interrupted.cause == .processEnded)
	}

	@Test func unclaimedTurnStaysAcceptedAwaitingRestart() async throws {
		let (before, dying) = processBeforeTheKill(
			coalescing: CoalescingPolicy(window: .seconds(60)))
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.dieWithoutWriting(to: dying)
		let recording = BatchRecordingLog(inner: store)
		let after = await relaunched(over: recording)
		let state = try #require(await after.state(of: turn))
		#expect(state == .accepted(.awaitingRestart))
		#expect(state.retryable)
		try await Task.sleep(for: .milliseconds(100))
		#expect(recording.batches.isEmpty)
		#expect(transport.requests.isEmpty)
		#expect(try await claims(of: turn).isEmpty)
	}

	@Test func settledClaimIsNotTouched() async throws {
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		let before = makeCoach(transport: transport, store: store, clock: clock)
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		let settled = try #require(await before.settledState(of: turn, in: .main))
		let recording = BatchRecordingLog(inner: store)
		let after = await relaunched(over: recording)
		#expect(await after.state(of: turn) == settled)
		#expect(recording.batches.isEmpty)
		#expect(try await settlements(of: turn).count == 1)
	}

	@Test func planRunTwiceWritesNothingTheSecondTime() async throws {
		transport.hangUntilCancelled = true
		let (before, dying) = processBeforeTheKill()
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.waitUntilProcessing(turn)
		await before.dieWithoutWriting(to: dying)
		let first = await relaunched()
		#expect(try await settlements(of: turn).count == 1)
		let recording = BatchRecordingLog(inner: store)
		let second = await relaunched(over: recording)
		#expect(recording.batches.isEmpty)
		#expect(await second.state(of: turn) == (await first.state(of: turn)))
		let synced = try await store.fetch(RecordQuery(scope: ConversationFold.syncedScope))
		let local = try await store.fetch(RecordQuery(scope: ConversationFold.localScope))
		let turns = ConversationFold.fold(
			chat: .main, synced: synced.records, local: local.records, device: store.deviceId
		).segments.flatMap(\.turns)
		#expect(
			TurnRecovery.plan(turns: turns, writes: [:], device: store.deviceId)
				== RecoveryPlan(interrupt: []))
	}

	@Test func deadClaimWithAnObservedReplyIsInterruptedAndNeverReplayed() {
		let device = DeviceID(rawValue: "phone-a")
		let turn = TurnID(ulid: fixedUlid(1))
		let attempt = AttemptID(ulid: fixedUlid(2))
		var facts = TurnFacts(turn: turn, chat: .main, origin: device)
		facts.fragments.append(
			Fragment(
				ulid: fixedUlid(1),
				hlc: HybridLogicalClock(wallMs: 1, logical: 0, deviceId: device),
				civilDate: "1998-06-13", index: 0, draft: DraftID(), text: "Thursday?", slash: nil))
		facts.claims.append(TurnClaimBody(chatId: .main, turn: turn, attempt: attempt))
		facts.replyObserved.append(ReplyObservedBody(chatId: .main, turn: turn, attempt: attempt))
		let plan = TurnRecovery.plan(turns: [facts], writes: [:], device: device)
		#expect(
			plan == RecoveryPlan(interrupt: [DeadClaim(turn: turn, attempt: attempt, saved: .none)])
		)
		let settle = TurnLifecycle.writes(
			for: .recoverDeadClaim(attempt, saved: .none), on: facts, chat: .main, device: device,
			mint: { turn })
		#expect(
			settle
				== .success(
					.synced([
						.turnSettled(
							TurnSettledBody(
								chatId: .main, turn: turn, attempt: attempt,
								settlement: .interrupted(
									partial: "", cause: .processEnded, saved: .none)))
					])))
		var settledFacts = facts
		settledFacts.settlements.append(
			SettledAttempt(
				ulid: fixedUlid(3),
				hlc: HybridLogicalClock(wallMs: 3, logical: 0, deviceId: device),
				civilDate: "1998-06-13", attempt: attempt,
				settlement: .interrupted(partial: "", cause: .processEnded, saved: .none)))
		#expect(
			TurnLifecycle.writes(
				for: .recoverDeadClaim(attempt, saved: .none), on: settledFacts, chat: .main,
				device: device, mint: { turn }) == .success(.nothing))
		#expect(
			TurnRecovery.plan(turns: [settledFacts], writes: [:], device: device)
				== RecoveryPlan(interrupt: []))
	}

	@Test func stampedWritesAreCountedPerAttempt() async throws {
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let turn = TurnID(ulid: fixedUlid(1))
		let dead = AttemptID(ulid: fixedUlid(2))
		let other = AttemptID(ulid: fixedUlid(3))
		let zone = AthleteCalendar(clock: clock).deviceZone
		func stamp(_ attempt: AttemptID) -> OperationStamp {
			OperationStamp(
				operation: .turn(turn), attempt: attempt,
				binding: ActionBinding(account: .unconnected, zone: zone))
		}
		let memory = Memory(ledger: ledger, clock: clock)
		try await memory.writeSection(
			SectionName(rawValue: "schedule"), content: "Saturdays.", source: .chat,
			stamp: stamp(dead))
		_ = try await memory.appendEvent(
			date: "1998-06-13", kind: .decision, text: "Rest on Monday.", source: .chat,
			stamp: stamp(dead))
		try await memory.writeSection(
			SectionName(rawValue: "goals"), content: "Gran fondo.", source: .chat,
			stamp: stamp(other))
		let records = try await store.fetch(RecordQuery(scope: TurnRecovery.stampedWrites))
			.records
		#expect(
			TurnRecovery.writes(of: [dead], in: records) == [
				dead: WriteSummary(
					memorySections: 1, ledgerEvents: 1, planSaves: 0, calendarWrites: 0)
			])
	}
}
