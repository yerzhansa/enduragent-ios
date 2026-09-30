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
