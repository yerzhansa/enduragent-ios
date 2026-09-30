import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationTrimImportTests {
	@Test func aRemoteTurnImportedAfterTheTrimStillReachesTheModel() async throws {
		let store = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		let transport = FakeModelTransport()
		transport.summaryScript = [.text("Earlier conversation."), .finish(reason: .stop)]
		transport.script = [
			.text("Thursday is on."), .finish(reason: .stop),
			.text("Saturday too."), .finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Is Thursday on?")
		let windows = try await store.fetch(
			RecordQuery(scope: .synced([.windowStart]), chatId: .main)
		).records
		let window = try #require(windows.first)
		guard case .synced(.windowStart(let trim)) = window.body else {
			Issue.record("expected a committed trim")
			return
		}
		let remote = DeviceID(rawValue: "remote-phone")
		let turn = TurnID(ulid: ULID.generate(at: clock.now.addingTimeInterval(-600)))
		#expect(turn.ulid < trim.firstIncludedUlid)
		#expect(trim.firstIncludedUlid.incremented() < window.ulid)
		try await seed(
			store,
			[
				storedRecord(
					device: remote, wall: 1, ulid: turn.ulid,
					body: .synced(sampleUser(chatId: .main, text: "Remote question", turn: turn))),
				storedRecord(
					device: remote, wall: 2, ulid: trim.firstIncludedUlid.incremented(),
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Remote answer"))),
			])
		_ = try await coach.sendAndSettle("And Saturday?")
		let prompt = try #require(sent(.chatAttempt, by: transport).last)
		#expect(prompt.messages.contains { $0.unstampedContent == "Remote question" })
		#expect(prompt.messages.contains { $0.content == "Remote answer" })
		#expect(sent(.droppedSummary, by: transport).count == 1)
	}
}
