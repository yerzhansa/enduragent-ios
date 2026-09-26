import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct RetryLadderTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func rateLimitRetriesThreeTimesHonoringRetryAfter() async throws {
		transport.script = Array(
			repeating: .fail(.http(status: 429, headers: ["retry-after": "7"])), count: 4)
		let coach = makeCoach()
		let turn = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(transport.requests.count == 4)
		#expect(clock.slept.prefix(3) == [.seconds(7), .seconds(7), .seconds(7)])
		#expect(failure(settled) == .model(.rateLimited(retryAfter: .seconds(7))))
		#expect(!settled.retryable)
	}

	@Test(arguments: [
		RateLimitRow(headers: [:], waits: [.seconds(5), .seconds(10), .seconds(20)]),
		RateLimitRow(
			headers: ["retry-after": "300"], waits: [.seconds(120), .seconds(120), .seconds(120)]),
		RateLimitRow(
			headers: ["retry-after-ms": "1500"],
			waits: [.milliseconds(1_500), .milliseconds(1_500), .milliseconds(1_500)]),
	])
	func rateLimitWaitsFollowTheHintOrBackOffUnderTheCeiling(row: RateLimitRow) async throws {
		transport.script = Array(
			repeating: .fail(.http(status: 429, headers: row.headers)), count: 4)
		_ = try await makeCoach().sendAndSettle("How was my week?")
		#expect(Array(clock.slept.prefix(row.waits.count)) == row.waits)
		#expect(chatRequests() == 4)
	}

	@Test func serverErrorRetriesTwiceWithJitteredWaits() async throws {
		transport.script = [
			.fail(.http(status: 500)),
			.fail(.connection(.networkConnectionLost)),
			.fail(.http(status: 503)),
			.text("Too late."),
			.finish(reason: .stop),
		]
		let settled = try await makeCoach().sendAndSettle("Is Thursday on?")
		#expect(failure(settled) == .model(.providerDown(.outage)))
		#expect(chatRequests() == 3)
		#expect(clock.slept.count == 2)
		#expect(clock.slept.allSatisfy { $0 >= .zero && $0 < .milliseconds(500) })
	}

	@Test func serverErrorWithRetryAfterWaitsFromTheHintUpToTheCap() async throws {
		transport.script = [
			.fail(.http(status: 503, headers: ["retry-after": "2"])),
			.fail(.http(status: 503, headers: ["retry-after": "30"])),
			.text("Thursday is on."),
			.finish(reason: .stop),
		]
		let settled = try await makeCoach().sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		#expect(chatRequests() == 3)
		let waits = clock.slept
		#expect(waits.count == 2)
		#expect(waits.first.map { $0 >= .seconds(2) && $0 < .seconds(3) } == true)
		#expect(waits.last == .seconds(5))
	}

	@Test func timeoutCompactsAboveRatioElseOnePlainRetry() async throws {
		transport.script = Array(repeating: .fail(.connection(.timedOut)), count: 3)
		let plain = try await makeCoach().sendAndSettle("Is Thursday on?")
		#expect(failure(plain) == .model(.providerDown(.timeout)))
		#expect(chatRequests() == 2)
		#expect(requests(.compaction) == 0)
		#expect(clock.slept.isEmpty)

		let large = FakeModelTransport()
		large.script = Array(repeating: .fail(.connection(.timedOut)), count: 3)
		let longRequest = String(repeating: "Thursday ride notes. ", count: 21_500)
		let crowded = try await makeCoach(transport: large).sendAndSettle(longRequest)
		#expect(failure(crowded) == .model(.providerDown(.timeout)))
		#expect(large.requests.filter { $0.charge == .chatAttempt }.count == 3)
		#expect(large.requests.filter { $0.charge == .compaction }.count == 2)
	}

	@Test func overflowFlushesOnceThenCompactsThreeTimes() async throws {
		transport.script =
			[.text("Yes, rest."), .finish(reason: .stop)]
			+ Array(repeating: .fail(overflow), count: 5)
		let coach = makeCoach()
		_ = try await coach.sendAndSettle("Rest day?")
		let settled = try await coach.sendAndSettle("How was my week?")
		#expect(failure(settled) == .model(.contextOverflow))
		#expect(chatRequests() == 1 + 4)
		#expect(requests(.memoryFlush) == 1)
		#expect(requests(.compaction) == 3)
		let summaries = try await store.fetch(
			RecordQuery(scope: .synced([.compactionSummary]), chatId: .main)
		).records
		#expect(summaries.count == 3)
	}

	@Test func budgetExceededIsTerminalBeforeAnyRung() async throws {
		transport.script =
			Array(repeating: .fail(overflow), count: 3) + [
				.fail(.http(status: 429)), .text("Never sent."), .finish(reason: .stop),
			]
		let settled = try await makeCoach().sendAndSettle("How was my week?")
		#expect(failure(settled) == .model(.budgetExhausted(.generateAttempts)))
		#expect(chatRequests() == 4)
		#expect(clock.slept == [.seconds(5)])

		let committedAndObserved = AttemptSituation(
			committed: [CommittedWrite(tool: .intervalsCreateWorkout)],
			observedText: true, promptTokens: 0, effectiveWindow: 200_000,
			flushLatchFree: true, accessMethod: .credits, jitter: 0)
		#expect(
			RetryLadder.npm.decide(
				.budget(TurnBudgetExceeded(kind: .wallClock)), situation: committedAndObserved,
				counters: .zero) == .terminal(.model(.budgetExhausted(.wallClock))))
	}

	@Test func committedCalendarWriteSettlesWritesSaved() {
		let calendar = situation(
			committed: [
				CommittedWrite(tool: .memoryWrite), CommittedWrite(tool: .intervalsCreateWorkout),
			])
		#expect(
			RetryLadder.npm.decide(
				.provider(.serverError(status: 500, retryAfter: nil)), situation: calendar,
				counters: .zero) == .settleSavedWork(.writesSaved))
		#expect(
			RetryLadder.npm.decide(.windowExceededFinish, situation: calendar, counters: .zero)
				== .settleSavedWork(.writesSaved))
		let notice = AthleteNotices.notice(for: .writesSaved)
		#expect(notice.key == Catalog.coachFallbackWritesSaved)
		#expect(notice.action == nil)
	}

	@Test func committedMemoryWriteSettlesSavedUnverified() async throws {
		transport.script = [
			.toolCall(
				name: "memory_write",
				arguments:
					#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
			),
			.finish(reason: .toolCalls),
			.fail(.http(status: 500)),
			.text("Never sent."),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		let turn = try #require(
			try await coach.send(draft("Remember my Saturday ride"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		guard case .savedWork(let savedWork) = settled else {
			Issue.record("expected saved work, got \(settled)")
			return
		}
		#expect(savedWork.outcome == .savedUnverified)
		#expect(
			savedWork.saved
				== WriteSummary(memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		)
		#expect(savedWork.notice.key == Catalog.chatNoticeSavedUnverified)
		#expect(savedWork.notice.action == nil)
		#expect(!settled.retryable)
		#expect(chatRequests() == 2)
		#expect(clock.slept.isEmpty)
		let section = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records.first)
		let claim = try #require(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn))
				.records.first)
		#expect(section.cause == claim.cause)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await coach.retry(turn, in: .main)
		}
		let reopened = makeCoach()
		#expect(try #require(await reopened.currentSnapshot(.main)).turns.first?.state == settled)
	}

	@Test func savedWorkReachesTheNextPromptAsTheCoachsReply() async throws {
		transport.script = [
			.toolCall(
				name: "memory_write",
				arguments:
					#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
			),
			.finish(reason: .toolCalls),
			.fail(.http(status: 500)),
		]
		let coach = makeCoach()
		let saved = try await coach.sendAndSettle("Remember my Saturday ride")
		guard case .savedWork = saved else {
			Issue.record("expected saved work, got \(saved)")
			return
		}
		transport.script = [.text("Saturdays are noted."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("Did you save it?")
		let prompt = try #require(transport.requests.last(where: { $0.charge == .chatAttempt }))
		let history = prompt.messages.filter { $0.role == .user || $0.role == .assistant }
		#expect(
			history.prefix(2).map(\.content) == [
				"Remember my Saturday ride",
				"I saved your information, but couldn't verify my response. Please try again.",
			])
		#expect(history.prefix(2).map(\.role) == [.user, .assistant])
	}

	@Test func observedTextIsTerminalExceptWindowExceeded() async throws {
		transport.script = [
			.text("Thursday is "),
			.fail(.connection(.networkConnectionLost)),
			.text("Never sent."),
			.finish(reason: .stop),
		]
		let cut = try await makeCoach().sendAndSettle("Is Thursday on?")
		#expect(failure(cut) == .model(.providerDown(.network)))
		#expect(chatRequests() == 1)

		let window = FakeModelTransport()
		window.finishUsage = Usage(
			inputTokens: TurnPolicy.contextWindowCap, outputTokens: 8, cost: nil)
		window.script = [
			.text("truncated"), .finish(reason: .length), .text("after compact"),
			.finish(reason: .stop),
		]
		let rescued = try await makeCoach(transport: window).sendAndSettle("Long history")
		#expect(replyText(rescued) == "after compact")
		#expect(window.requests.filter { $0.charge == .chatAttempt }.count == 2)
		#expect(window.requests.filter { $0.charge == .compaction }.count == 1)

		let observed = situation(observedText: true)
		#expect(
			RetryLadder.npm.decide(.provider(.network), situation: observed, counters: .zero)
				== .terminal(.model(.providerDown(.network))))
		guard
			case .retry(_, let preparations) = RetryLadder.npm.decide(
				.windowExceededFinish, situation: observed, counters: .zero)
		else {
			Issue.record("expected the window-exceeded finish to retry")
			return
		}
		#expect(preparations == [.flushMemory(.overflow), .compactInTurn])
	}

	@Test func failedCompactionRescueEndsWithTheOriginalFailure() async throws {
		let faulty = FaultInjectingRecordLog(wrapping: store)
		faulty.failAppends(ofKind: .compactionSummary)
		transport.script = [.fail(overflow), .text("Never sent."), .finish(reason: .stop)]
		let coach = EnduragentCoachTests.makeCoach(
			transport: transport, store: faulty, clock: clock)
		let settled = try await coach.sendAndSettle("How was my week?")
		#expect(failure(settled) == .model(.contextOverflow))
		#expect(chatRequests() == 1)
		#expect(
			coach.diagnostics.entries.contains { entry in
				if case .compactionFailed(.main, _) = entry.event { return true }
				return false
			})
	}

	@Test func waitShowsTheWorkingStateWithItsReason() async throws {
		let paused = PausingClock(calendar: clock)
		transport.script = [
			.fail(.http(status: 429, headers: ["retry-after": "7"])),
			.text("Thursday is on."),
			.finish(reason: .stop),
		]
		let coach = EnduragentCoachTests.makeCoach(
			transport: transport, store: store, clock: paused)
		let turn = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		var sleeping = paused.sleeping.makeAsyncIterator()
		#expect(await sleeping.next() == .seconds(7))
		let waiting = try #require(await coach.currentSnapshot(.main))
		guard case .processing(let processing)? = waiting.turns.first?.state else {
			Issue.record("expected processing, got \(String(describing: waiting.turns.first))")
			return
		}
		#expect(processing.liveText.isEmpty)
		#expect(
			processing.activity
				== .waiting(RetryWait(until: clock.now.addingTimeInterval(7), reason: .rateLimited))
		)
		#expect(waiting.activity == .working(label: Catalog.chatNoticeWorking))
		paused.resume()
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "Thursday is on.")
	}

	@Test func eachRungStopsAtItsNpmLimit() {
		let ladder = RetryLadder.npm
		let limits: [(AttemptFailure, Int)] = [
			(.provider(.contextOverflow), 3),
			(.provider(.rateLimited(retryAfter: nil)), 3),
			(.provider(.serverError(status: 502, retryAfter: nil)), 2),
			(.provider(.network), 2),
			(.provider(.timeout(.firstToken)), 1),
			(.provider(.credentialRejected(status: 401)), 0),
			(.provider(.invalidRequest), 0),
			(.provider(.accessExhausted), 0),
			(.provider(.unknownFinish), 0),
			(.generation(.emptyAfterError), 0),
		]
		for (failure, limit) in limits {
			var counters = RetryCounters.zero
			var retries = 0
			while case .retry(let next, _) = ladder.decide(
				failure, situation: situation(), counters: counters)
			{
				counters = next
				retries += 1
			}
			#expect(retries == limit, "\(failure)")
		}
	}

	private var overflow: ScriptedFailure {
		.http(status: 400, body: #"{"error":{"message":"maximum context length exceeded"}}"#)
	}

	private func situation(
		committed: [CommittedWrite] = [], observedText: Bool = false
	) -> AttemptSituation {
		AttemptSituation(
			committed: committed, observedText: observedText, promptTokens: 1_000,
			effectiveWindow: TurnPolicy.contextWindowCap, flushLatchFree: true,
			accessMethod: .credits, jitter: 0.5)
	}

	private func chatRequests() -> Int {
		requests(.chatAttempt)
	}

	private func requests(_ charge: GenerateCharge) -> Int {
		transport.requests.filter { $0.charge == charge }.count
	}

	private func makeCoach(transport: FakeModelTransport? = nil) -> Coach {
		EnduragentCoachTests.makeCoach(
			transport: transport ?? self.transport, store: store, clock: clock)
	}
}

struct RateLimitRow: Sendable, CustomTestStringConvertible {
	let headers: [String: String]
	let waits: [Duration]

	var testDescription: String { headers.isEmpty ? "no hint" : "\(headers)" }
}

private final class PausingClock: Clock, @unchecked Sendable {
	let calendar: FixedClock
	let sleeping: AsyncStream<Duration>
	private let started: AsyncStream<Duration>.Continuation
	private let lock = NSLock()
	private var parked: CheckedContinuation<Void, Never>?

	init(calendar: FixedClock) {
		self.calendar = calendar
		(sleeping, started) = AsyncStream<Duration>.makeStream()
	}

	var now: Date { calendar.now }
	var timeZone: TimeZone { calendar.timeZone }
	var uptime: Duration { calendar.uptime }

	func sleep(for duration: Duration) async throws {
		started.yield(duration)
		await withCheckedContinuation { continuation in
			lock.withLock { parked = continuation }
		}
	}

	func resume() {
		let waiting = lock.withLock {
			defer { parked = nil }
			return parked
		}
		waiting?.resume()
	}
}
