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
		let result = try await runner().run(attempt("Keep fetching", scope: scope), scope: scope) {
			_ in
		}
		#expect(result.replyText == "Ten steps.")
		#expect(transport.requests.count == 10)
		await #expect(throws: TurnBudgetExceeded(kind: .generateCalls)) {
			try await scope.chargeCall()
		}
	}

	@Test func preemptiveCompactionIsNotAnOverflowRetry() async throws {
		try await seedReplies(tokens: [100_000, 100_000, 50, 50])
		transport.summaryScript = [
			.fail(.http(status: 500)), .text("Short."), .finish(reason: .stop),
		]
		transport.script =
			Array(
				repeating: .fail(
					.http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#)),
				count: 3)
			+ [.text("Fits now."), .finish(reason: .stop)]
		let scope = TurnScope(stamp: testStamp(), policy: .npm, uptime: .zero)
		let result = try await runner().run(attempt("Is Thursday on?", scope: scope), scope: scope)
		{
			_ in
		}
		#expect(result.replyText == "Fits now.")
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 1 + 3)
		#expect(transport.requests.filter { $0.charge == .droppedSummary }.count == 1)
		#expect(transport.requests.filter { $0.charge == .compaction }.count == 1)
	}

	@Test func waitThatPassesTheWallClockEndsTheTurnBeforeTheNextAttempt() async throws {
		transport.script =
			Array(repeating: .fail(.http(status: 429, headers: ["retry-after": "7"])), count: 2)
			+ [.text("Too late."), .finish(reason: .stop)]
		let tight = TurnBudgetPolicy(
			maxGenerateAttempts: 2, maxGenerateCalls: 40, wallClock: .seconds(10),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: tight, uptime: clock.uptime)
		let result = try await runner().run(attempt("Is Thursday on?", scope: scope), scope: scope)
		{
			_ in
		}
		#expect(
			result == .failed(.model(.budgetExhausted(.wallClock)), saved: .none))
		#expect(transport.requests.count == 2)
		#expect(clock.slept == [.seconds(7), .seconds(7)])
	}

	@Test func budgetFailureAfterAMemoryWriteKeepsTheWriteInTheSettlement() async throws {
		transport.script = [
			.toolCall(
				name: "memory_write",
				arguments:
					#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
			),
			.finish(reason: .toolCalls),
			.finish(reason: .toolCalls),
		]
		let oneCall = TurnBudgetPolicy(
			maxGenerateAttempts: 4, maxGenerateCalls: 1, wallClock: .seconds(600),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: oneCall, uptime: .zero)
		let result = try await runner().run(
			attempt("Remember Saturdays", scope: scope), scope: scope
		) {
			_ in
		}
		#expect(
			result
				== .failed(
					.model(.budgetExhausted(.generateCalls)),
					saved: WriteSummary(
						memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
				))
		#expect(transport.requests.map(\.charge) == [.chatAttempt, .chatAttempt])
	}

	@Test func inTurnFlushIsChargedAgainstTheTurnsCalls() async throws {
		transport.script = [.text("Yes, rest."), .finish(reason: .stop)]
		_ = try await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock
		).sendAndSettle("Rest day?")
		transport.script = [
			.fail(.http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#))
		]
		let twoCalls = TurnBudgetPolicy(
			maxGenerateAttempts: 4, maxGenerateCalls: 2, wallClock: .seconds(600),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: twoCalls, uptime: .zero)
		let result = try await runner().run(attempt("How was my week?", scope: scope), scope: scope)
		{
			_ in
		}
		#expect(result == .failed(.model(.budgetExhausted(.generateCalls)), saved: .none))
		#expect(transport.requests.map(\.charge) == [.chatAttempt, .chatAttempt, .memoryFlush])
	}

	private func seedReplies(tokens: [Int]) async throws {
		for (index, size) in tokens.enumerated() {
			let asked = clock.now.addingTimeInterval(TimeInterval(-60 * (tokens.count - index)))
			let turn = TurnID(ulid: ULID.generate(at: asked))
			try await seed(
				store,
				[
					seededRecord(
						store, at: asked, ulid: turn.ulid,
						body: .synced(
							sampleUser(chatId: .main, text: "Question \(index)", turn: turn))),
					seededRecord(
						store, at: asked.addingTimeInterval(1),
						ulid: ULID.generate(at: asked.addingTimeInterval(1)),
						body: .synced(
							sampleReply(
								chatId: .main, turn: turn,
								text: String(repeating: "w", count: Int(Double(size) / 1.2 * 4))))),
				])
		}
	}

	private func runner() -> TurnRunner {
		let diagnostics = DiagnosticsLog(clock: clock)
		let ledger = Ledger(log: store, clock: clock, diagnostics: diagnostics)
		return TurnRunner(
			transport: transport,
			ledger: ledger,
			clock: clock,
			diagnostics: diagnostics,
			ladder: .npm,
			evidence: WellnessEvidence(clock: clock, diagnostics: diagnostics)
		)
	}

	private func attempt(_ request: String, scope: TurnScope) -> TurnAttempt {
		TurnAttempt(
			turn: TurnID(ulid: scope.stamp.attempt.ulid),
			attempt: scope.stamp.attempt,
			origin: .send,
			chat: .main,
			request: request,
			slash: nil,
			language: LanguagePreference.automatic.replyLanguage(for: request, device: .en),
			session: .npmDefaults,
			access: testAccess,
			training: TrainingConnection(
				account: .intervals(connection: ConnectionID(), athlete: nil), client: intervals),
			process: ProcessID(ulid: scope.stamp.attempt.ulid)
		)
	}
}

extension AttemptResult {
	fileprivate var replyText: String? {
		guard case .replied(.model(let text), _) = self else { return nil }
		return text
	}
}
