import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationTrimMigrationTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func legacyTrimAtAnAssistantRowSummarizesOnce() async throws {
		let budget = historyBudget(clock: clock)
		let firstPad = String(repeating: "a", count: budget * 2)
		let secondPad = String(repeating: "b", count: budget * 5 / 3)
		let start = clock.now.addingTimeInterval(-3_600)
		func at(_ index: Int) -> (wall: Int64, ulid: ULID) {
			let date = start.addingTimeInterval(TimeInterval(index))
			return (Int64(date.timeIntervalSince1970 * 1_000), ULID.generate(at: date))
		}
		let stamps = (0..<7).map(at)
		let kept = TurnID(ulid: stamps[5].ulid)
		let bodies: [RecordBody] = [
			legacyUser(chatId: .main, text: "Legacy first question"),
			legacyReply(chatId: .main, text: "Legacy first answer " + firstPad),
			legacyUser(chatId: .main, text: "Legacy second question"),
			legacyReply(chatId: .main, text: "Legacy second answer " + secondPad),
			.legacy(.windowStartV1(chatId: .main, firstIncludedUlid: stamps[1].ulid)),
			.synced(sampleUser(chatId: .main, text: "Kept question", turn: kept)),
			.synced(sampleReply(chatId: .main, turn: kept, text: "Kept answer")),
		]
		try await seed(
			store,
			zip(stamps, bodies).map { stamp, body in
				storedRecord(device: store.deviceId, wall: stamp.wall, ulid: stamp.ulid, body: body)
			})
		transport.summaryScript = Array(
			repeating: [.text("Earlier conversation."), .finish(reason: .stop)], count: 4
		).flatMap { $0 }
		transport.script = [
			.text("Thursday is on."), .finish(reason: .stop),
			.text("Saturday too."), .finish(reason: .stop),
			.text("Sunday off."), .finish(reason: .stop),
		]
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, store: store, clock: clock)
		let firstPrompt = try await sendCapturing("Is Thursday on?", coach)
		#expect(sent(.droppedSummary, by: transport).count == 1)
		#expect(!firstPrompt.contains { $0.content.contains("Legacy first answer") })
		#expect(!firstPrompt.contains { $0.unstampedContent == "Legacy first question" })
		#expect(firstPrompt.contains { $0.unstampedContent == "Legacy second question" })
		let second = try await sendCapturing("And Saturday?", coach)
		let last = try await sendCapturing("And Sunday?", coach)
		#expect(sent(.droppedSummary, by: transport).count == 1)
		#expect(!second.contains { $0.content.contains("Legacy first answer") })
		#expect(!last.contains { $0.content.contains("Legacy first answer") })
	}

	private func sendCapturing(_ text: String, _ coach: Coach) async throws -> [WireMessage] {
		_ = try await coach.sendAndSettle(text)
		return try #require(sent(.chatAttempt, by: transport).last).messages
	}
}
