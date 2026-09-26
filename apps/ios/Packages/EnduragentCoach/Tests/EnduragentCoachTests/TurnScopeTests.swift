import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnScopeTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func memoIsPerAttemptNotPerRuntime() async throws {
		let store = InMemoryRecordLog()
		let tools = ToolRuntime(
			intervals: intervals,
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			planning: Planning(store: store, intervals: intervals, clock: clock),
			clock: clock
		)
		let mainChat = scope()
		let otherChat = scope()
		let week = try JSONValue.parse(#"{"days":7}"#)
		_ = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, chatId: .main, scope: mainChat)
		_ = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, chatId: "other", scope: otherChat)
		_ = try await tools.execute(
			name: .intervalsFetchActivities, arguments: week, chatId: .main, scope: mainChat)
		#expect(intervals.calls == [.activities(days: 7), .activities(days: 7)])
		_ = try await tools.execute(
			name: .memoryWrite,
			arguments: try JSONValue.parse(#"{"type":"daily","content":"Easy spin today."}"#),
			chatId: .main, scope: mainChat)
		#expect(await mainChat.written == [CommittedWrite(tool: .memoryWrite)])
		#expect(await otherChat.written.isEmpty)
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
		let turn = TurnScope(stamp: testStamp(), policy: .npm, uptime: .seconds(30))
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
		transport.script = [
			.toolCall(
				name: "memory_write",
				arguments:
					#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
			),
			.finish(reason: .toolCalls),
			.hang,
		]
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
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
		#expect(interrupted.notice.action == nil)
		#expect(!settled.retryable)
	}

	private func scope() -> TurnScope {
		TurnScope(stamp: testStamp(), policy: .npm, uptime: .zero)
	}
}
