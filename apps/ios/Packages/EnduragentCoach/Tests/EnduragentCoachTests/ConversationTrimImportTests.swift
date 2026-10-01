import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationTrimImportTests {
	@Test func aRemoteTurnImportedDuringATrimmedReplyReachesTheLiveConversation() async throws {
		let store = ImportingRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier conversation."), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is"), .hang], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		let local = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(local)
		let observed = ImportSnapshots(await coach.observe(.main))
		let remote = DeviceID(rawValue: "remote-phone")
		let turn = TurnID(ulid: ULID.generate(at: clock.now.addingTimeInterval(-600)))
		try await seed(
			store,
			[
				storedRecord(
					device: remote, wall: 1, ulid: turn.ulid,
					body: .synced(sampleUser(chatId: .main, text: "Remote question", turn: turn))),
				storedRecord(
					device: remote, wall: 2, ulid: turn.ulid.incremented(),
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Remote answer"))),
			])
		store.notifyImport()
		try await waitUntil { observed.latest?.turns.contains { $0.id == turn } == true }
		await coach.stop(.main)
		#expect(try await settlements(of: local, in: store).count == 1)
		#expect(sent(.droppedSummary, by: transport).count == 1)
		let live = await coach.currentSnapshot(.main)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		#expect(live == (await reopened.currentSnapshot(.main)))
		transport.respond = ScriptedReply.sequence(
			[.text("Saturday too."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		_ = try await coach.sendAndSettle("And Saturday?")
		let prompt = try #require(sent(.chatAttempt, by: transport).last)
		#expect(prompt.messages.contains { $0.unstampedContent == "Remote question" })
		#expect(prompt.messages.contains { $0.content == "Remote answer" })
		#expect(prompt.messages.contains { $0.content.contains("Earlier conversation.") })
		#expect(!prompt.messages.contains { $0.unstampedContent == "Question 0" })

	}

	@Test func aRemoteTurnImportedAfterTheTrimStillReachesTheModel() async throws {
		let store = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier conversation."), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[
				.text("Thursday is on."), .finish(reason: .stop),
				.text("Saturday too."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
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
