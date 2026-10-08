import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnRunnerTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func tenthStepRunsToolsThenStops() async throws {
		intervals.activities = [
			.ride(name: "Sunday long ride", date: "1998-06-07", durationS: 7200, trainingLoad: 120)
		]
		var script: [ScriptedEvent] = []
		for _ in 0..<10 {
			script.append(.text("."))
			script.append(.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#))
			script.append(.finish(reason: .toolCalls))
		}
		transport.respond = ScriptedReply.sequence(
			script, otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Keep fetching")
		#expect(replyText(settled) == ".")
		#expect(transport.requests.count == 10)
	}

	@Test func lifecycleRecordsCarryTheirTurnAccountAndAttemptStamps() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Noted."), .finish(reason: .stop)], otherwise: transport.respond)
		let recording = BatchRecordingLog(inner: store)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: recording, clock: clock)
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		let everyKind: [String] = recording.batches.flatMap { $0 }
		#expect(!everyKind.contains("assistantMessage"))
		let synced = try await store.fetch(
			RecordQuery(scope: .synced([.userMessage, .turnSettled]), chatId: "main")
		).records
		let local = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), chatId: "main")
		)
		.records
		#expect(synced.map(\.body.kind) == ["userMessage", "turnSettled"])
		#expect(local.map(\.body.kind) == ["turnClaim"])
		#expect(Set((synced + local).map(\.body.turn)) == [turn])
		let connected = TrainingAccount.intervals(
			connection: testConnection.id, athlete: testConnection.resolvedAthlete)
		#expect(synced.map(\.account) == [.unconnected, connected])
		#expect(local.map(\.account) == [connected])
		guard case .operation(.turn(let claimedTurn), let attempt)? = local.first?.cause else {
			Issue.record("expected a turn stamp on the claim")
			return
		}
		#expect(claimedTurn == turn)
		#expect(synced.last?.cause == .operation(.turn(turn), attempt))
		guard case .operation(.turn(let acceptedTurn), let acceptAttempt)? = synced.first?.cause
		else {
			Issue.record("expected a turn stamp on the accept")
			return
		}
		#expect(acceptedTurn == turn)
		#expect(acceptAttempt != attempt)
		#expect(await coach.transcript(.main) == ["Remember Saturdays", "Noted."])
	}

	@Test func toolErrorReturnsToTheModelAsAResult() async throws {
		let failure = IntervalsError(code: "down", details: "intervals.icu is unavailable.")
		intervals.setWellnessOutcome(.failure(failure))
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "intervals_fetch_wellness", arguments: #"{"days":7}"#),
				.finish(reason: .toolCalls),
				.text("I could not read your wellness data."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("How am I recovering?")
		#expect(replyText(settled) == "I could not read your wellness data.")
		#expect(transport.requests.count == 2)
		let toolMessage = try #require(
			transport.requests[1].messages.last(where: { $0.role == .tool }))
		#expect(toolMessage.content.contains("intervals.icu is unavailable."))
	}

	@Test func aToolThatCannotSaveTellsTheModelInPlainWords() async throws {
		let failing = FaultInjectingRecordLog(wrapping: store)
		try failing.failAppends(ofKind: "ledgerEvent")
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "ledger_append",
					arguments:
						#"{"kind":"decision","date":"1998-06-13","text":"Rides on Saturdays"}"#),
				.finish(reason: .toolCalls),
				.text("I could not save that."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: failing, clock: clock)
		let settled = try await coach.sendAndSettle("Remember that I ride on Saturdays")
		#expect(replyText(settled) == "I could not save that.")
		let toolMessage = try #require(
			transport.requests[1].messages.last(where: { $0.role == .tool }))
		#expect(
			toolMessage.content
				== JSONValue.object([
					"error": .string("save_failed"),
					"details": .string("The change could not be saved on this device."),
				]).canonicalDigestInput())
		#expect(!toolMessage.content.contains("LedgerFailure"))
		#expect(transport.requests[1].attempt == transport.requests[0].attempt)
		let failures = coach.diagnostics.entries.compactMap { entry -> ToolFault? in
			guard
				case .toolFailed(transport.requests[0].attempt, .ledgerAppend, let failure) = entry
					.event
			else { return nil }
			return failure
		}
		#expect(failures == [.saveFailed])
	}

	@Test func providerErrorsSettleAsTypedFailures() async throws {
		transport.respond = ScriptedReply.sequence(
			Array(repeating: .fail(.connection(.notConnectedToInternet)), count: 3), for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach()
		let network = try await coach.sendAndSettle("one")
		#expect(failure(network) == .model(.providerDown(.network)))
		transport.respond = ScriptedReply.sequence(
			[.fail(ScriptedFailure(.unknownFinish))], otherwise: transport.respond)
		let finish = try await coach.sendAndSettle("two")
		#expect(failure(finish) == .model(.generationFailed(.unknownFinish)))
		#expect(await coach.transcript(.main) == ["one", "two"])
		let prompt = try #require(transport.requests.last)
		#expect(prompt.messages.filter { $0.role == .user }.count == 1)
	}

	@Test(arguments: FailureRow.all)
	func everyProviderFailureSettlesWithItsNotice(row: FailureRow) async throws {
		transport.respond = ScriptedReply.sequence(
			Array(repeating: .fail(row.scripted), count: row.calls), for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach()
		let turn = try #require(try await coach.send(draft("Plan my week"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		guard case .failed(let failed) = settled else {
			Issue.record("expected a failed turn, got \(settled)")
			return
		}
		#expect(failed.failure == .model(row.failure))
		#expect(failed.notice?.key == row.key)
		#expect(failed.notice?.actions.map { english.say($0.title) } == row.buttons)
		let waits = CoachFailure.model(row.failure).tryAgainWait != nil
		#expect(
			(failed.notice?.actions == [.tryAgain(turn)])
				== (row.buttons == ["Try again"] && !waits))
		#expect(failed.notice?.sentence(in: displayLocale()) == row.english)
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == row.calls)
	}

	@Test func watchdogFireIsATimeoutThatRetriesOnce() async throws {
		transport.respond = ScriptedReply.sequence(
			[.hang, .text("Back on track."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let clock = HeldClock()
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, store: store, clock: clock, watchdogClock: clock)
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		try await clock.waitUntilHeld(.seconds(30))
		clock.advance(by: .seconds(30))
		let settled = try #require(
			await coach.settledState(of: turn, in: .main, within: .hangGuard))
		#expect(replyText(settled) == "Back on track.")
		#expect(clock.slept == [.seconds(30)])
		#expect(transport.requests.count == 2)
		let claim = try #require(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn))
				.records.first)
		guard case .operation(_, let attempt) = claim.cause else {
			Issue.record("expected a turn stamp on the claim")
			return
		}
		#expect(
			coach.diagnostics.entries.map(\.event) == [
				.providerFailure(attempt, .timeout(.firstToken), detail: "")
			])
	}

	@Test func trimSummarizesDroppedMessagesWithCompactionModel() async throws {
		let history = try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		transport.respond = ScriptedReply.sequence(
			[.text(earlierSummary), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let settled = try await makeCoach().sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		#expect(transport.requests.map(\.charge) == [.memoryFlush, .droppedSummary, .chatAttempt])
		let summary = try #require(sent(.droppedSummary, by: transport).first)
		#expect(summary.model == testModel)
		#expect(summary.tools.isEmpty)
		let asked = try #require(summary.messages.last?.content)
		#expect(
			asked.contains(
				"Messages to incorporate:\nuser: [Sat 1998-06-13 07:57 Europe/Amsterdam] Question 0\nassistant: Answer 0"
			))
		#expect(!asked.contains("Question 1"))
		let chat = try #require(sent(.chatAttempt, by: transport).first)
		#expect(
			chat.messages.dropFirst().prefix(2).map(\.content) == [
				"[Previous conversation summary]\n" + earlierSummary,
				"[Sat 1998-06-13 07:58 Europe/Amsterdam] Question 1",
			])
		let written = try await store.fetch(
			RecordQuery(scope: .synced([.windowStart, .compactionSummary]), chatId: .main)
		).records.map(\.body)
		#expect(
			written == [
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: history[1].user, reason: .trim,
							droppedMessageUlids: [history[0].user, history[0].reply]))),
				.synced(
					.compactionSummary(
						CompactionSummaryBody(chatId: .main, markdown: earlierSummary))),
			])
	}

	@Test func failedSummaryKeepsDroppedMessagesInPrompt() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		transport.respond = ScriptedReply.sequence(
			[.fail(.http(status: 500))], for: .summary, otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		let chat = try #require(sent(.chatAttempt, by: transport).first)
		let history = chat.messages.dropFirst().map(\.content)
		#expect(history.first == "[Sat 1998-06-13 07:57 Europe/Amsterdam] Question 0")
		#expect(history.filter { $0.contains("] Question") }.count == 3)
		#expect(!history.contains { $0.hasPrefix("[Previous conversation summary]") })
		#expect(
			try await store.fetch(
				RecordQuery(scope: .synced([.windowStart, .compactionSummary]), chatId: .main)
			).records.isEmpty)
		#expect(
			coach.diagnostics.entries.contains { entry in
				if case .compactionFailed(.main, _) = entry.event { return true }
				return false
			})
	}

	@Test func latestSummaryIsSentFirstOnNextTurn() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		transport.respond = ScriptedReply.sequence(
			[.text(earlierSummary), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[
				.text("Thursday is on."), .finish(reason: .stop), .text("Saturday too."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Is Thursday on?")
		let settled = try await coach.sendAndSettle("And Saturday?")
		#expect(replyText(settled) == "Saturday too.")
		#expect(sent(.droppedSummary, by: transport).count == 1)
		let next = try #require(sent(.chatAttempt, by: transport).last)
		#expect(
			next.messages.dropFirst().prefix(2).map(\.content) == [
				"[Previous conversation summary]\n" + earlierSummary,
				"[Sat 1998-06-13 07:58 Europe/Amsterdam] Question 1",
			])
		#expect(next.messages.dropFirst().map(\.content).contains("Thursday is on."))
	}

	@Test func historyBudgetUsesTheStoredRatio() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) / 2)
		transport.respond = ScriptedReply.sequence(
			[.text(earlierSummary), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[
				.text("Thursday is on."), .finish(reason: .stop), .text("Saturday too."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Is Thursday on?")
		#expect(sent(.droppedSummary, by: transport).isEmpty)
		try await coach.setSession(
			SessionSettings.npmDefaults.replacing(.historyBudgetRatio, with: "5"))
		_ = try await coach.sendAndSettle("And Saturday?")
		#expect(sent(.droppedSummary, by: transport).count == 1)
		let next = try #require(sent(.chatAttempt, by: transport).last)
		#expect(
			next.messages.dropFirst().first?.content.hasPrefix("[Previous conversation summary]")
				== true)
	}

}

private let english = CatalogPhrasebook(tag: .en)
private let earlierSummary = "## Athlete Profile\n- Rides Saturdays with a group"
