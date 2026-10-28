import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct UsageLineTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let store = InMemoryRecordLog()
	let journal = MemoryJournalStorage()
	let share: ShareFolder
	let transport: FakeModelTransport

	init() throws {
		share = ShareFolder(in: try TestTemporaryFolders.make())
		transport = FakeModelTransport(clock: clock)
		transport.finishUsage = Usage(inputTokens: 1_200, outputTokens: 300, cost: 0.25)
	}

	@Test func aTurnLineSumsItsCalls() async throws {
		transport.respond = { request in
			request.step == 0
				? ScriptedReply(
					[remember("Group ride on Saturdays."), .finish(reason: .toolCalls)],
					requestDelay: .milliseconds(700))
				: ScriptedReply(
					[.text("Saturdays are noted."), .finish(reason: .stop)],
					requestDelay: .milliseconds(800))
		}
		let coach = await makeCoach()
		let turn = try #require(
			try await coach.send(draft("Remember my Saturday ride"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		#expect(transport.requests.map(\.charge) == [.chatAttempt, .chatAttempt])
		let attempt = try #require(try await attempts(of: turn).first)
		#expect(
			try lines() == [
				UsageLine(
					origin: .turn(turn: turn.ulid, attempt: attempt, ending: .replied),
					model: try #require(ModelRef(testModel)), calls: 2, failedCalls: 0,
					inputTokens: 2_400, outputTokens: 600, cost: .reported(0.5),
					durationMilliseconds: 1_500)
			])
	}

	@Test func tryAgainWritesASecondLineForTheSameTurn() async throws {
		transport.respond = ScriptedReply.sequence(
			[.fail(.http(status: 400)), .text("Thursday is on."), .finish(reason: .stop)],
			for: .chat, otherwise: transport.respond)
		let coach = await makeCoach()
		let turn = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		try await coach.retry(turn, in: .main)
		let written = try await waitForLines(2)
		let attempts = try await attempts(of: turn)
		#expect(attempts.count == 2)
		#expect(Set(attempts).count == 2)
		#expect(
			written.map(\.origin) == [
				.turn(turn: turn.ulid, attempt: try #require(attempts.first), ending: .failed),
				.turn(turn: turn.ulid, attempt: try #require(attempts.last), ending: .replied),
			])
		#expect(written.map(\.calls) == [0, 1])
		#expect(written.map(\.failedCalls) == [1, 0])
	}

	@Test func aStreamThatFailsOnceAndRecoversCountsTheFailure() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.fail(.connection(.networkConnectionLost)), .text("Thursday is on."),
				.finish(reason: .stop),
			], for: .chat, otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		let line = try #require(try lines().first)
		#expect(try lines().count == 1)
		#expect(line.calls == 1)
		#expect(line.failedCalls == 1)
		#expect(Self.ending(of: line) == .replied)
	}

	@Test func aTurnWhoseEveryCallFailsCountsEachAttempt() async throws {
		transport.respond = ScriptedReply.sequence(
			Array(repeating: .fail(.connection(.notConnectedToInternet)), count: 3), for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(failure(settled) == .model(.providerDown(.network)))
		let line = try #require(try lines().first)
		#expect(try lines().count == 1)
		#expect(line.calls == 0)
		#expect(line.failedCalls == 3)
		#expect(line.failedCalls == sent(.chatAttempt, by: transport).count)
		#expect(Self.ending(of: line) == .failed)
	}

	@Test func aFlushJobWritesOneMemorySaveLine() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.respond = ScriptedReply.sequence(
			[.text("Noted."), .finish(reason: .stop)], otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[
				remember("Group ride on Saturdays."), .finish(reason: .toolCalls),
				.finish(reason: .stop),
			],
			for: .flush, otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Remember Saturdays")
		#expect(replyText(settled) == "Noted.")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		let flushes = sent(.memoryFlush, by: transport)
		let attempt = try #require(flushes.first).attempt.ulid
		let saves = try lines().filter { Self.ending(of: $0) == nil }
		#expect(
			saves.map(\.origin) == [.memorySave(attempt: attempt, ending: .saved)])
		#expect(saves.map(\.calls) == [flushes.count])
		#expect(try lines().filter { Self.ending(of: $0) != nil }.map(\.calls) == [1])
	}

	@Test func aNewConversationFlushWritesOneMemorySaveLine() async throws {
		try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		transport.respond = ScriptedReply.sequence(
			[
				remember("Group ride on Saturdays."), .finish(reason: .toolCalls),
				.finish(reason: .stop),
			],
			for: .flush, otherwise: transport.respond)
		let coach = await makeCoach()
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let flushes = sent(.memoryFlush, by: transport)
		let attempt = try #require(flushes.first).attempt.ulid
		let written = try lines()
		#expect(written.map(\.origin) == [.memorySave(attempt: attempt, ending: .saved)])
		#expect(written.map(\.calls) == [flushes.count])
	}

	@Test func anInTurnMemorySaveIsCountedInTheTurnLine() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier: three questions."), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		#expect(transport.requests.map(\.charge) == [.memoryFlush, .droppedSummary, .chatAttempt])
		let written = try lines()
		#expect(written.count == 1)
		#expect(written.map { Self.ending(of: $0) } == [.replied])
		#expect(written.map(\.calls) == [3])
	}

	@Test func anInTurnCompactionIsCountedInTheTurnLine() async throws {
		try await seedHistory(store, clock: clock, turns: 3, tokens: 300)
		transport.respond = ScriptedReply.sequence(
			[
				.fail(
					.http(
						status: 400,
						body: #"{"error":{"message":"maximum context length exceeded"}}"#)),
				.text("Thursday is on."), .finish(reason: .stop),
			], for: .chat, otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier: three questions."), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		#expect(sent(.compaction, by: transport).count == 1)
		let written = try lines()
		#expect(written.count == 1)
		#expect(written.map(\.calls) == [transport.requests.count - 1])
		#expect(written.map(\.failedCalls) == [1])
		#expect(written.map { Self.ending(of: $0) } == [.replied])
	}

	@Test func aSeededSentenceIsInNoUsageLine() async throws {
		let sentence = "Lena climbs the Stelvio every August before dawn."
		transport.respond = ScriptedReply.sequence(
			[
				remember(sentence), .finish(reason: .toolCalls), .text(sentence),
				.finish(reason: .stop),
			],
			for: .chat, otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle(sentence)
		#expect(replyText(settled) == sentence)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let flushed = try #require(sent(.memoryFlush, by: transport).first)
		#expect(flushed.messages.contains { $0.content.contains(sentence) })
		#expect(try lines().count == 2)
		let bytes = String(decoding: try #require(journal.contents), as: UTF8.self)
		#expect(!bytes.contains(sentence))
		#expect(!bytes.contains("Stelvio"))
	}

	private func makeCoach() async -> Coach {
		await EnduragentCoachTests.makeCoach(
			transport: transport, store: store, clock: clock,
			support: SupportService(
				journal: journal, shareFolder: share, app: .fixture, device: .fixture))
	}

	private func remember(_ content: String) -> ScriptedEvent {
		.toolCall(
			name: "memory_write",
			arguments: #"{"type":"memory","section":"schedule","content":"\#(content)"}"#)
	}

	private func lines() throws -> [UsageLine] {
		guard let contents = journal.contents else { return [] }
		return try contents.split(separator: UInt8(ascii: "\n")).compactMap { line in
			guard case .usage(let usage) = try StampedLine(decoding: Data(line)).line else {
				return nil
			}
			return usage
		}
	}

	private func waitForLines(_ count: Int) async throws -> [UsageLine] {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while try lines().count < count {
			guard ContinuousClock.now < deadline else { throw TestWaitDeadlineExceeded() }
			try await Task.sleep(for: .milliseconds(10))
		}
		return try lines()
	}

	private func attempts(of turn: TurnID) async throws -> [ULID] {
		try await claims(of: turn, in: store).compactMap { record in
			guard case .operation(_, let attempt) = record.cause else { return nil }
			return attempt.ulid
		}
	}

	private static func ending(of line: UsageLine) -> TurnUsageEnding? {
		guard case .turn(_, _, let ending) = line.origin else { return nil }
		return ending
	}
}
