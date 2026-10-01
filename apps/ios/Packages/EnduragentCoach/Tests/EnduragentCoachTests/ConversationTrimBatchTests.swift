import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationTrimBatchTests {
	let store = InMemoryRecordLog()
	let transport = FakeModelTransport()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let remote = DeviceID(rawValue: "remote-phone")

	@Test(arguments: [512, 513])
	func trimCoverageIsBoundedWithoutResummarizingOrHidingImports(turnCount: Int) async throws {
		let dropped = try await seedDroppedTurns(count: turnCount)
		transport.summaryScript = Array(
			repeating: [.text("Earlier conversation."), .finish(reason: .stop)], count: 3
		).flatMap { $0 }
		transport.script = [
			.text("Thursday is on."), .finish(reason: .stop),
			.text("Saturday too."), .finish(reason: .stop),
			.text("Sunday off."), .finish(reason: .stop),
		]
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Is Thursday on?")
		let windows = try await store.fetch(
			RecordQuery(scope: .synced([.windowStart]), chatId: .main)
		).records
		#expect(windows.count == (dropped.count + 1_023) / 1_024)
		var recorded: [ULID] = []
		for record in windows {
			guard case .synced(.windowStart(let body)) = record.body else {
				Issue.record("expected a committed trim")
				return
			}
			let ids = try #require(body.droppedMessageUlids)
			#expect(!ids.isEmpty)
			#expect(ids.count <= 1_024)
			#expect(try RecordCodec.encode(record.body).data.count < 32_768)
			recorded += ids
		}
		#expect(Set(recorded) == Set(dropped))
		#expect(recorded.count == dropped.count)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let mailbox = await coach.mailbox(for: .main)
		#expect(await mailbox.conversation == (try await ledger.conversation(.main)))
		_ = try await coach.sendAndSettle("And Saturday?")
		let second = try #require(sent(.chatAttempt, by: transport).last)
		#expect(!second.messages.contains { $0.content.contains("Dropped") })
		#expect(second.messages.contains { $0.unstampedContent == "Kept question" })
		#expect(second.messages.contains { $0.content == "Kept answer" })
		try await seed(
			store,
			turnRecords(at: 1, question: "Late remote question", answer: "Late remote answer"))
		_ = try await coach.sendAndSettle("And Sunday?")
		let last = try #require(sent(.chatAttempt, by: transport).last)
		#expect(last.messages.contains { $0.unstampedContent == "Late remote question" })
		#expect(last.messages.contains { $0.content == "Late remote answer" })
		#expect(!last.messages.contains { $0.content.contains("Dropped") })
		#expect(sent(.droppedSummary, by: transport).count == 1)
	}

	private func seedDroppedTurns(count: Int) async throws -> [ULID] {
		var records: [AthleteRecord] = []
		for index in 0..<count {
			let padding =
				index == count - 1
				? String(repeating: "w", count: historyBudget(clock: clock) * 4) : ""
			records += turnRecords(
				at: 10 + index * 2, question: "Dropped question \(index)",
				answer: "Dropped answer \(index) " + padding)
		}
		let dropped = records.map(\.ulid)
		records += turnRecords(
			at: 10 + count * 2, question: "Kept question", answer: "Kept answer")
		try await seed(store, records)
		return dropped
	}

	private func turnRecords(at index: Int, question: String, answer: String) -> [AthleteRecord] {
		let turn = TurnID(ulid: fixedUlid(index))
		return [
			storedRecord(
				device: remote, wall: Int64(index), ulid: turn.ulid,
				body: .synced(sampleUser(chatId: .main, text: question, turn: turn))),
			storedRecord(
				device: remote, wall: Int64(index + 1), ulid: fixedUlid(index + 1),
				body: .synced(sampleReply(chatId: .main, turn: turn, text: answer))),
		]
	}
}
