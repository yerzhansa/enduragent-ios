import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CompactionTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let overflow = ScriptedFailure.http(
		status: 400, body: #"{"error":{"message":"maximum context length exceeded"}}"#)

	@Test func overflowWithNothingToDropMakesNoCompactionCallAndKeepsTheHistory() async throws {
		transport.script =
			[.text("Yes, rest."), .finish(reason: .stop)]
			+ Array(repeating: .fail(overflow), count: 4)
			+ [.text("Tuesday is easy."), .finish(reason: .stop)]
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Rest day?")
		let settled = try await coach.sendAndSettle("How was my week?")
		#expect(failure(settled) == .model(.contextOverflow))
		#expect(sent(.chatAttempt, by: transport).count == 1 + 4)
		#expect(sent(.memoryFlush, by: transport).count == 1)
		#expect(sent(.compaction, by: transport).isEmpty)
		#expect(try await chatWindowRecords().isEmpty)
		_ = try await coach.sendAndSettle("And Tuesday?")
		let last = try #require(sent(.chatAttempt, by: transport).last)
		#expect(last.messages.contains { $0.unstampedContent == "Rest day?" })
		#expect(last.messages.contains { $0.unstampedContent == "Yes, rest." })
	}

	@Test func inTurnCompactionSummarizesForTheAttemptAndRewritesNoHistory() async throws {
		try await seedHistory(store, clock: clock, turns: 3, tokens: 300)
		transport.script = [.fail(overflow), .text("Thursday is on."), .finish(reason: .stop)]
		transport.summaryScript = [.text("Earlier: three questions."), .finish(reason: .stop)]
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		let asked = try #require(sent(.compaction, by: transport).only).messages.last?.content
		#expect(
			asked?.contains(
				"user: [Sat 1998-06-13 07:57 Europe/Amsterdam] Question 0\nassistant: Answer 0")
				== true)
		let retry = try #require(sent(.chatAttempt, by: transport).last).messages.dropFirst()
		#expect(
			retry.first?.content == "[Previous conversation summary]\nEarlier: three questions.")
		#expect(!retry.contains { $0.unstampedContent == "Question 0" })
		#expect(try await chatWindowRecords().isEmpty)
		transport.script = [.text("Saturday too."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("And Saturday?")
		let next = try #require(sent(.chatAttempt, by: transport).last).messages.dropFirst()
		#expect(next.first?.content == "[Sat 1998-06-13 07:57 Europe/Amsterdam] Question 0")
		#expect(!next.contains { $0.content.hasPrefix("[Previous conversation summary]") })
	}

	@Test func failedCompactionKeepsTheMessagesAndRetriesWhenTheyFit() async throws {
		try await seedHistory(store, clock: clock, turns: 3, tokens: 300)
		transport.script = [.fail(overflow), .text("Thursday is on."), .finish(reason: .stop)]
		transport.summaryScript = [.fail(.http(status: 500))]
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(replyText(settled) == "Thursday is on.")
		#expect(sent(.compaction, by: transport).count == 1)
		let retry = try #require(sent(.chatAttempt, by: transport).last).messages.dropFirst()
		#expect(retry.first?.content == "[Sat 1998-06-13 07:57 Europe/Amsterdam] Question 0")
		#expect(try await chatWindowRecords().isEmpty)
		#expect(compactionFailed(coach))
	}

	@Test func failedCompactionThatStillOverflowsEndsWithTheOriginalFailure() async throws {
		try await seedHistory(store, clock: clock, turns: 3, tokens: 210_000)
		transport.script = [.text("Never sent."), .finish(reason: .stop)]
		transport.summaryScript = [.fail(.http(status: 500)), .fail(.http(status: 500))]
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(failure(settled) == .model(.contextOverflow))
		#expect(sent(.droppedSummary, by: transport).count == 1)
		#expect(sent(.compaction, by: transport).count == 1)
		#expect(sent(.chatAttempt, by: transport).isEmpty)
		#expect(try await chatWindowRecords().isEmpty)
		#expect(compactionFailed(coach))
	}

	@Test func trimmedHistoryPersistsTheFixtureSummaryMarkdown() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		transport.summaryScript = [
			.text("Summary of the earlier conversation."), .finish(reason: .stop),
		]
		transport.script = [
			.text("Thursday is on."), .finish(reason: .stop),
			.text("Saturday too."), .finish(reason: .stop),
		]
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Is Thursday on?")
		_ = try await coach.sendAndSettle("And Saturday?")
		let summaries = try await chatWindowRecords().compactMap { record -> String? in
			guard case .synced(.compactionSummary(let body)) = record.body else { return nil }
			return body.markdown
		}
		#expect(summaries == ["Summary of the earlier conversation."])
		let next = try #require(sent(.chatAttempt, by: transport).last)
		#expect(
			next.messages.dropFirst().first?.content
				== "[Previous conversation summary]\nSummary of the earlier conversation.")
	}

	@Test(arguments: [FinishReason.error, .contentFilter, .stop], ["", " \t\n "])
	func emptySummaryKeepsHistoryAndPreviousSummaryAfterReopening(
		reason: FinishReason, text: String
	) async throws {
		try await assertRejectedSummaryKeepsHistory(text: text, reason: reason)
	}

	@Test(arguments: [FinishReason.error, .contentFilter])
	func failedSummaryKeepsHistoryAndPreviousSummaryAfterReopening(reason: FinishReason)
		async throws
	{
		try await assertRejectedSummaryKeepsHistory(text: "Incomplete summary.", reason: reason)
	}

	private func assertRejectedSummaryKeepsHistory(text: String, reason: FinishReason) async throws
	{
		let previous = seededRecord(
			store, at: clock.now.addingTimeInterval(-600), ulid: fixedUlid(1),
			body: .synced(
				.compactionSummary(
					CompactionSummaryBody(chatId: .main, markdown: "Previous cycling context."))))
		try await seed(store, [previous])
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		transport.summaryScript = Array(
			repeating: [.text(text), .finish(reason: reason)], count: 3
		).flatMap { $0 }
		transport.script = [
			.text("Thursday is on."), .finish(reason: .stop),
			.text("Saturday too."), .finish(reason: .stop),
			.text("Sunday is rest."), .finish(reason: .stop),
		]
		let coach = await makeCoach()
		#expect(replyText(try await coach.sendAndSettle("Is Thursday on?")) == "Thursday is on.")
		#expect(replyText(try await coach.sendAndSettle("And Saturday?")) == "Saturday too.")
		#expect(try await chatWindowRecords() == [previous])
		#expect(compactionFailed(coach))
		let reopened = await makeCoach()
		#expect(replyText(try await reopened.sendAndSettle("And Sunday?")) == "Sunday is rest.")
		#expect(try await chatWindowRecords() == [previous])
		#expect(compactionFailed(reopened))
		#expect(sent(.droppedSummary, by: transport).count == 3)
		let prompts = sent(.chatAttempt, by: transport)
		#expect(prompts.count == 3)
		for prompt in prompts {
			let keepsEarliestQuestion = prompt.messages.contains {
				$0.unstampedContent == "Question 0"
			}
			let keepsPreviousSummary = prompt.messages.contains {
				$0.content == "[Previous conversation summary]\nPrevious cycling context."
			}
			#expect(keepsEarliestQuestion)
			#expect(keepsPreviousSummary)
		}
	}

	@Test func interleavedTrimIsSummarizedOnce() async throws {
		let droppedReply =
			"Dropped answer " + String(repeating: "w", count: historyBudget(clock: clock) * 4)
		try await seedInterleavedHistory(firstReply: droppedReply)
		transport.summaryScript = Array(
			repeating: [.text("Earlier conversation."), .finish(reason: .stop)], count: 2
		).flatMap { $0 }
		transport.script = [
			.text("Thursday is on."), .finish(reason: .stop),
			.text("Saturday too."), .finish(reason: .stop),
		]
		let coach = await makeCoach()
		#expect(replyText(try await coach.sendAndSettle("Is Thursday on?")) == "Thursday is on.")
		#expect(replyText(try await coach.sendAndSettle("And Saturday?")) == "Saturday too.")
		#expect(sent(.droppedSummary, by: transport).count == 1)
		let prompts = sent(.chatAttempt, by: transport)
		#expect(prompts.count == 2)
		for prompt in prompts {
			#expect(!prompt.messages.contains { $0.unstampedContent == "Dropped question" })
			#expect(!prompt.messages.contains { $0.content.contains("Dropped answer") })
			#expect(prompt.messages.contains { $0.unstampedContent == "Kept question" })
			#expect(prompt.messages.contains { $0.content == "Kept answer" })
		}
		let windows = try await chatWindowRecords().compactMap { record -> ULID? in
			guard case .synced(.windowStart(let body)) = record.body else { return nil }
			return body.firstIncludedUlid
		}
		#expect(windows == [fixedUlid(2)])
	}

	@Test func aTrimmedLegacyQuestionWithoutAReplyStaysDropped() async throws {
		let budget = historyBudget(clock: clock)
		let orphan = "Orphan question " + String(repeating: "o", count: budget * 2)
		let legacyReplyText = "Legacy answer " + String(repeating: "l", count: budget * 5 / 3)
		let kept = TurnID(ulid: fixedUlid(4))
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 1, ulid: fixedUlid(1),
					body: legacyUser(chatId: .main, text: orphan)),
				storedRecord(
					device: store.deviceId, wall: 2, ulid: fixedUlid(2),
					body: legacyUser(chatId: .main, text: "Legacy question")),
				storedRecord(
					device: store.deviceId, wall: 3, ulid: fixedUlid(3),
					body: legacyReply(chatId: .main, text: legacyReplyText)),
				storedRecord(
					device: store.deviceId, wall: 4, ulid: fixedUlid(4),
					body: .synced(sampleUser(chatId: .main, text: "Kept question", turn: kept))),
				storedRecord(
					device: store.deviceId, wall: 5, ulid: fixedUlid(5),
					body: .synced(sampleReply(chatId: .main, turn: kept, text: "Kept answer"))),
			])
		transport.summaryScript = Array(
			repeating: [.text("Earlier conversation."), .finish(reason: .stop)], count: 2
		).flatMap { $0 }
		transport.script = [
			.text("Thursday is on."), .finish(reason: .stop),
			.text("Saturday too."), .finish(reason: .stop),
		]
		let coach = await makeCoach()
		#expect(replyText(try await coach.sendAndSettle("Is Thursday on?")) == "Thursday is on.")
		#expect(replyText(try await coach.sendAndSettle("And Saturday?")) == "Saturday too.")
		#expect(sent(.droppedSummary, by: transport).count == 1)
		let prompts = sent(.chatAttempt, by: transport)
		#expect(prompts.count == 2)
		for prompt in prompts {
			#expect(!prompt.messages.contains { $0.content.contains("Orphan question") })
			#expect(prompt.messages.contains { $0.unstampedContent == "Legacy question" })
			#expect(prompt.messages.contains { $0.content == legacyReplyText })
			#expect(prompt.messages.contains { $0.unstampedContent == "Kept question" })
			#expect(prompt.messages.contains { $0.content == "Kept answer" })
		}
		let windows = try await chatWindowRecords().compactMap { record -> ULID? in
			guard case .synced(.windowStart(let body)) = record.body else { return nil }
			return body.firstIncludedUlid
		}
		#expect(windows == [fixedUlid(2)])
	}

	@Test func aSettlementAfterTheTrimStaysInLaterPrompts() async throws {
		try await seedInterleavedHistory(firstReply: "Late answer")
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 3, ulid: fixedUlid(3),
					body: .synced(
						.windowStart(
							WindowStartBody(
								chatId: .main, firstIncludedUlid: fixedUlid(2), reason: .trim))))
			])
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		#expect(
			replyText(try await makeCoach().sendAndSettle("Is Thursday on?")) == "Thursday is on.")
		let prompt = try #require(sent(.chatAttempt, by: transport).only)
		#expect(prompt.messages.contains { $0.unstampedContent == "Dropped question" })
		#expect(prompt.messages.contains { $0.content == "Late answer" })
		#expect(sent(.droppedSummary, by: transport).isEmpty)
	}

	private func seedInterleavedHistory(firstReply: String) async throws {
		let first = TurnID(ulid: fixedUlid(1))
		let second = TurnID(ulid: fixedUlid(2))
		let bodies: [(Int, SyncedRecordBody)] = [
			(1, sampleUser(chatId: .main, text: "Dropped question", turn: first)),
			(2, sampleUser(chatId: .main, text: "Kept question", turn: second)),
			(4, sampleReply(chatId: .main, turn: first, text: firstReply)),
			(5, sampleReply(chatId: .main, turn: second, text: "Kept answer")),
		]
		try await seed(
			store,
			bodies.map { offset, body in
				storedRecord(
					device: store.deviceId, wall: Int64(offset), ulid: fixedUlid(offset),
					body: .synced(body))
			})
	}

	private func chatWindowRecords() async throws -> [AthleteRecord] {
		try await store.fetch(
			RecordQuery(scope: .synced([.windowStart, .compactionSummary]), chatId: .main)
		).records
	}

	private func compactionFailed(_ coach: Coach) -> Bool {
		coach.diagnostics.entries.contains { entry in
			if case .compactionFailed(.main, _) = entry.event { return true }
			return false
		}
	}

	private func makeCoach() async -> Coach {
		await EnduragentCoachTests.makeCoach(transport: transport, store: store, clock: clock)
	}
}

extension Array {
	fileprivate var only: Element? {
		count == 1 ? first : nil
	}
}
