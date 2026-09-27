import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct HistoryMigrationTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let firstChat: ChatID = "0f6c1d2e-6b1a-4f0e-9d7a-2b9c3e4f5a61"
	let secondChat: ChatID = "7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d"

	func seedV1Chat(_ chat: ChatID, asking question: String, reply: String, hoursAgo: Double)
		async throws
	{
		let asked = clock.now.addingTimeInterval(-hoursAgo * 3_600)
		let answered = asked.addingTimeInterval(2)
		try await seed(
			store,
			[
				seededRecord(
					store, at: asked, ulid: ULID.generate(at: asked),
					body: legacyUser(chatId: chat, text: question)),
				seededRecord(
					store, at: answered, ulid: ULID.generate(at: answered),
					body: legacyReply(chatId: chat, text: reply)),
			])
	}

	func coach() -> Coach {
		makeCoach(transport: transport, store: store, clock: clock)
	}

	@Test func v1ChatsBecomeArchivedConversationsAndMainOpensOnWelcome() async throws {
		try await seedV1Chat(
			firstChat, asking: "How was my week?", reply: "Two rides.", hoursAgo: 48)
		try await seedV1Chat(
			secondChat, asking: "Is Thursday still on?", reply: "Yes, keep it.", hoursAgo: 2)
		let coach = coach()
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .welcome)
		let archived = try await coach.history()
		#expect(archived.map(\.reason) == [.earlierChat, .earlierChat])
		#expect(archived.map(\.id.rawValue) == [secondChat.rawValue, firstChat.rawValue])
		#expect(
			archived.map { $0.turns.map(\.athleteText) }
				== [["Is Thursday still on?"], ["How was my week?"]])
		#expect(
			archived.map { $0.turns.compactMap { replyText($0.state) } } == [
				["Yes, keep it."], ["Two rides."],
			])
		#expect(archived.map(\.startedOn) == ["1998-06-13", "1998-06-13"])
		#expect(try await store.fetch(RecordQuery(scope: .everySynced)).records.count == 4)
		#expect(transport.requests.isEmpty)
	}

	@Test func historyIssuesNoModelRequest() async throws {
		let seeded = try await seedHistory(store, clock: clock, turns: 2, tokens: 400)
		try await seed(
			store,
			[
				seededRecord(
					store, at: clock.now.addingTimeInterval(-5),
					ulid: ULID.generate(at: clock.now.addingTimeInterval(-5)),
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, trigger: .softThreshold,
								messageUlids: [seeded[0].user, seeded[0].reply]))))
			])
		try await seedV1Chat(
			firstChat, asking: "How was my week?", reply: "Two rides.", hoursAgo: 48)
		let archived = try await coach().history()
		try await Task.sleep(for: .milliseconds(300))
		#expect(archived.map(\.reason) == [.earlierChat])
		#expect(transport.requests.isEmpty)
	}
}
