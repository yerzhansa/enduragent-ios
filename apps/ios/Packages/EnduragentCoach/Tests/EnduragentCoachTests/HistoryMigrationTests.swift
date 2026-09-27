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

extension SwiftDataSuites {
	@Suite struct HistoryOpenTests {
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test func fiftyArchivedConversationsReadInUnderOneSecond() async throws {
			let store = try SwiftDataSuites.makeSwiftDataLog(
				deviceId: DeviceID(rawValue: "phone-a"))
			for index in 1...50 {
				let asked = clock.now.addingTimeInterval(TimeInterval(-600 + index * 10))
				let turn = TurnID(ulid: ULID.generate(at: asked))
				let boundary = ULID.generate(at: asked.addingTimeInterval(2))
				try await seed(
					store,
					[
						seededRecord(
							store, at: asked, ulid: turn.ulid,
							body: .synced(
								sampleUser(chatId: .main, text: "Archived \(index)", turn: turn))),
						seededRecord(
							store, at: asked.addingTimeInterval(1),
							ulid: ULID.generate(at: asked.addingTimeInterval(1)),
							body: .synced(
								sampleReply(chatId: .main, turn: turn, text: "Reply \(index)"))),
						seededRecord(
							store, at: asked.addingTimeInterval(2), ulid: boundary,
							body: .synced(
								.windowStart(
									WindowStartBody(
										chatId: .main, firstIncludedUlid: boundary,
										reason: .reset(.explicit(ResetID(ulid: boundary))))))),
					])
			}
			let coach = makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
			let started = ContinuousClock.now
			let archived = try await coach.history()
			let elapsed = ContinuousClock.now - started
			#expect(archived.count == 50)
			#expect(archived.first?.turns.first?.athleteText == "Archived 50")
			#expect(elapsed < .seconds(1), "History of 50 took \(elapsed)")
		}
	}
}
