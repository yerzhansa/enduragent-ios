import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnScopeTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func memoIsPerAttemptNotPerRuntime() async throws {
		let store = InMemoryRecordLog()
		let tools = makeOfferedTools(
			intervals: intervals,
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		)
		let mainChat = scope()
		let otherChat = scope()
		let week = try JSONValue.parse(#"{"oldest":"1998-06-07"}"#)
		_ = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, scope: mainChat)
		_ = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, scope: otherChat)
		_ = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, scope: mainChat)
		#expect(
			intervals.calls == [
				.activities(oldest: "1998-06-07", newest: "1998-06-13"),
				.activities(oldest: "1998-06-07", newest: "1998-06-13"),
			])
		_ = try await tools.execute(
			name: .memoryWrite,
			arguments: try JSONValue.parse(#"{"type":"daily","content":"Easy spin today."}"#),
			scope: mainChat)
		#expect(await mainChat.written == [CommittedWrite(tool: .memoryWrite)])
		#expect(await otherChat.written.isEmpty)
	}

	@Test func cancelledReadDoesNotEvictItsReplacement() async throws {
		let held = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let read = held.hold(.activities)
		held.fail(.activities, with: URLError(.cancelled))
		let ledger = Ledger(
			log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let heldTools = makeOfferedTools(intervals: held, ledger: ledger, clock: clock)
		let tools = makeOfferedTools(
			intervals: intervals, ledger: ledger, clock: clock)
		let turn = scope()
		let week = try JSONValue.parse(#"{"oldest":"1998-06-07"}"#)
		let original = Task {
			try await heldTools.execute(
				name: .intervalsFetchActivities, arguments: week, scope: turn)
		}
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { original.cancel() }) {
				await read.waitUntilEntered()
			} != nil)
		await turn.evict([.intervalsFetchActivities])
		let replacement = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, scope: turn)
		original.cancel()
		await #expect(throws: URLError(.cancelled)) {
			try await original.value
		}
		let cached = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, scope: turn)
		#expect(cached == replacement)
		#expect(intervals.calls == [.activities(oldest: "1998-06-07", newest: "1998-06-13")])
	}

	@Test func flushLatchReturnsTrueOnce() async {
		let turn = scope()
		#expect(await turn.flushLatchFree)
		#expect(await turn.takeFlushLatch())
		#expect(await !turn.takeFlushLatch())
		#expect(await !turn.flushLatchFree)
		#expect(await scope().takeFlushLatch())
	}

	@Test func budgetCountsCallsAttemptsAndUptime() async throws {
		let turn = TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .seconds(30))
		for _ in 0..<TurnBudgetPolicy.npm.maxGenerateCalls {
			try await turn.chargeCall()
		}
		await #expect(throws: TurnBudgetExceeded(kind: .generateCalls)) {
			try await turn.chargeCall()
		}
		for _ in 0..<TurnBudgetPolicy.npm.maxGenerateAttempts {
			try await turn.chargeAttempt()
		}
		await #expect(throws: TurnBudgetExceeded(kind: .generateAttempts)) {
			try await turn.chargeAttempt()
		}
		try await turn.checkDeadline(uptime: .seconds(30 + 599))
		#expect(await turn.callDeadline(uptime: .seconds(30 + 590)) == .seconds(10))
		#expect(await turn.callDeadline(uptime: .seconds(30)) == .seconds(600))
		await #expect(throws: TurnBudgetExceeded(kind: .wallClock)) {
			try await turn.checkDeadline(uptime: .seconds(30 + 600))
		}
	}

	@Test func stopAfterACommittedWriteOffersNoTryAgain() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.saturdayScheduleWrite,
				.finish(reason: .toolCalls),
				.hang,
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		let turn = try #require(
			try await coach.send(draft("Remember my Saturday ride"), to: .main).acceptedTurn)
		for await snapshot in await coach.observe(.main) {
			if case .processing(let processing)? = snapshot.turns.first?.state,
				processing.activity == .generating(step: 2)
			{
				break
			}
		}
		await coach.stop(.main)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected interrupted, got \(settled)")
			return
		}
		#expect(interrupted.saved.memorySections == 1)
		#expect(interrupted.notice.actions.isEmpty)
	}

	private func scope() -> TurnScope {
		TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
	}
}
