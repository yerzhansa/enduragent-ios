import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnBudgetTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func tenStepChatInvocationChargesOneCall() async throws {
		var script: [ScriptedEvent] = []
		for _ in 0..<9 {
			script.append(.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#))
			script.append(.finish(reason: .toolCalls))
		}
		script.append(contentsOf: [.text("Ten steps."), .finish(reason: .stop)])
		transport.script = script
		let oneCall = TurnBudgetPolicy(
			maxGenerateAttempts: 1, maxGenerateCalls: 1, wallClock: .seconds(600),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: oneCall, uptime: .zero)
		let report = try await runner().run(attempt("Keep fetching", scope: scope), scope: scope) {
			_ in
		}
		#expect(report.result.replyText == "Ten steps.")
		#expect(transport.requests.count == 10)
		await #expect(throws: TurnBudgetExceeded(kind: .generateCalls)) {
			try await scope.chargeCall()
		}
	}

	@Test func preemptiveCompactionIsNotAnOverflowRetry() async throws {
		transport.script = [.text("Yes, rest."), .finish(reason: .stop)]
		_ = try await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock
		).sendAndSettle("Rest day?")
		transport.script =
			Array(
				repeating: .fail(
					.http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#)),
				count: 3)
			+ [.text("Fits now."), .finish(reason: .stop)]
		let scope = TurnScope(stamp: testStamp(), policy: .npm, uptime: .zero)
		let crowded = String(repeating: "Saturday group ride notes. ", count: 25_000)
		let report = try await runner().run(attempt(crowded, scope: scope), scope: scope) { _ in }
		#expect(report.result.replyText == "Fits now.")
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 1 + 4)
		#expect(transport.requests.filter { $0.charge == .compaction }.count == 1 + 3 * 2)
		#expect(transport.requests.filter { $0.charge == .memoryFlush }.count == 1)
	}

	@Test func waitThatPassesTheWallClockEndsTheTurnBeforeTheNextAttempt() async throws {
		transport.script =
			Array(repeating: .fail(.http(status: 429, headers: ["retry-after": "7"])), count: 2)
			+ [.text("Too late."), .finish(reason: .stop)]
		let tight = TurnBudgetPolicy(
			maxGenerateAttempts: 2, maxGenerateCalls: 40, wallClock: .seconds(10),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: tight, uptime: clock.uptime)
		let report = try await runner().run(attempt("Is Thursday on?", scope: scope), scope: scope)
		{
			_ in
		}
		#expect(
			report.result == .failed(.model(.budgetExhausted(.wallClock)), saved: .none))
		#expect(transport.requests.count == 2)
		#expect(clock.slept == [.seconds(7), .seconds(7)])
	}

	private func runner() -> TurnRunner {
		let diagnostics = DiagnosticsLog(clock: clock)
		let ledger = Ledger(log: store, clock: clock, diagnostics: diagnostics)
		let planning = Planning(store: store, intervals: intervals, clock: clock)
		return TurnRunner(
			transport: transport,
			intervals: intervals,
			ledger: ledger,
			clock: clock,
			tools: ToolRuntime(
				intervals: intervals, ledger: ledger, planning: planning, clock: clock),
			planning: planning,
			diagnostics: diagnostics,
			ladder: .npm
		)
	}

	private func attempt(_ request: String, scope: TurnScope) -> TurnAttempt {
		TurnAttempt(
			turn: TurnID(ulid: scope.stamp.attempt.ulid),
			attempt: scope.stamp.attempt,
			chat: .main,
			request: request,
			slash: nil,
			language: LanguagePreference(ui: .en, coachReply: nil),
			access: testAccess
		)
	}
}

extension AttemptResult {
	fileprivate var replyText: String? {
		guard case .replied(.model(let text), _) = self else { return nil }
		return text
	}
}
