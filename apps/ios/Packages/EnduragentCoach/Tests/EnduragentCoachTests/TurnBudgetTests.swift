import EnduragentCoachFixtures
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
		transport.respond = ScriptedReply.sequence(
			script, otherwise: transport.respond)
		let oneCall = TurnBudgetPolicy(
			maxGenerateAttempts: 1, maxGenerateCalls: 1, wallClock: .seconds(600),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: oneCall, ladder: .npm, uptime: .zero)
		let result = try await run("Keep fetching", scope: scope)
		#expect(result.replyText == "Ten steps.")
		#expect(transport.requests.count == 10)
		await #expect(throws: TurnBudgetExceeded(kind: .generateCalls)) {
			try await scope.chargeCall()
		}
	}

	@Test func preemptiveCompactionIsNotAnOverflowRetry() async throws {
		try await seedReplies(tokens: [100_000, 100_000, 50, 50])
		transport.respond = ScriptedReply.sequence(
			[
				.fail(.http(status: 500)), .text("Short."), .finish(reason: .stop),
			], for: .summary, otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			Array(
				repeating: .fail(
					.http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#)),
				count: 3)
				+ [.text("Fits now."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let scope = TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		let result = try await run("Is Thursday on?", scope: scope)
		#expect(result.replyText == "Fits now.")
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 1 + 3)
		#expect(transport.requests.filter { $0.charge == .droppedSummary }.count == 1)
		#expect(transport.requests.filter { $0.charge == .compaction }.count == 1)
	}

	@Test func waitThatPassesTheWallClockEndsTheTurnBeforeTheNextAttempt() async throws {
		transport.respond = ScriptedReply.sequence(
			Array(repeating: .fail(.http(status: 429, headers: ["retry-after": "7"])), count: 2)
				+ [.text("Too late."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let tight = TurnBudgetPolicy(
			maxGenerateAttempts: 2, maxGenerateCalls: 40, wallClock: .seconds(10),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: tight, ladder: .npm, uptime: clock.uptime)
		let result = try await run("Is Thursday on?", scope: scope)
		#expect(
			result == .failed(.model(.budgetExhausted(.wallClock)), saved: .none))
		#expect(transport.requests.count == 2)
		#expect(clock.slept == [.seconds(7), .seconds(7)])
	}

	@Test func budgetFailureAfterAMemoryWriteKeepsTheWriteInTheSettlement() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.saturdayScheduleWrite,
				.finish(reason: .toolCalls),
				.finish(reason: .toolCalls),
			], otherwise: transport.respond)
		let oneCall = TurnBudgetPolicy(
			maxGenerateAttempts: 4, maxGenerateCalls: 1, wallClock: .seconds(600),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: oneCall, ladder: .npm, uptime: .zero)
		let result = try await run("Remember Saturdays", scope: scope)
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
		transport.respond = ScriptedReply.sequence(
			[.text("Yes, rest."), .finish(reason: .stop)], otherwise: transport.respond)
		_ = try await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock
		).sendAndSettle("Rest day?")
		transport.respond = ScriptedReply.sequence(
			[
				.fail(.http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#))
			], otherwise: transport.respond)
		let twoCalls = TurnBudgetPolicy(
			maxGenerateAttempts: 4, maxGenerateCalls: 2, wallClock: .seconds(600),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
		let scope = TurnScope(stamp: testStamp(), policy: twoCalls, ladder: .npm, uptime: .zero)
		let result = try await run("How was my week?", scope: scope)
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

	@Test func inTurnFlushUsesTheTurnsLadder() async throws {
		try await seedReplies(tokens: [200])
		transport.respond = ScriptedReply.sequence(
			[
				.fail(.http(status: 400, body: "maximum context length")),
				.text("Recovered."), .finish(reason: .stop),
			], for: .chat, otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.fail(.http(status: 429)), .finish(reason: .stop)], for: .flush,
			otherwise: transport.respond)
		let ladder = RetryLadder(
			guards: RetryLadder.npm.guards,
			rungs: RetryLadder.npm.rungs.filter { !$0.classes.contains(.rateLimit) })
		let scope = TurnScope(
			stamp: testStamp(), policy: .npm, ladder: ladder, uptime: clock.uptime)
		let result = try await run("How was my week?", scope: scope, ladder: ladder)
		#expect(result.replyText == "Recovered.")
		#expect(sent(.memoryFlush, by: transport).count == 1)
		#expect(clock.slept.isEmpty)
	}

	private func run(_ request: String, scope: TurnScope, ladder: RetryLadder = .npm) async throws
		-> AttemptResult
	{
		let diagnostics = DiagnosticsLog(clock: clock)
		let ledger = Ledger(log: store, clock: clock, diagnostics: diagnostics)
		let conversation = try await ledger.conversation(.main)
		let jobs = try await ledger.flushJobs(in: conversation)
		let runner = TurnRunner(
			transport: transport,
			ledger: ledger,
			clock: clock,
			diagnostics: diagnostics,
			ladder: ladder,
			evidence: WellnessEvidence(clock: clock, diagnostics: diagnostics),
			reviews: makeReviews(ledger: ledger, clock: clock),
			authorizeInvocation: { _ in }
		)
		return try await runner.run(
			attempt(request, scope: scope), conversation: conversation, jobs: jobs,
			scope: scope, committed: { _ in }, progress: { _ in })
	}

	private func attempt(_ request: String, scope: TurnScope) -> TurnAttempt {
		TurnAttempt(
			turn: TurnID(ulid: scope.stamp.attempt.ulid),
			attempt: scope.stamp.attempt,
			origin: .send,
			chat: .main,
			request: request,
			slash: nil,
			displayLocale: testDisplayLocale(.automatic),
			session: .npmDefaults,
			access: testAccess,
			training: TrainingConnection(
				account: testConnection.account, client: intervals),
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
