import EnduragentCoachFixtures
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

	func coach() async -> Coach {
		await makeCoach(transport: transport, store: store, clock: clock)
	}

	@Test func v1ChatsBecomeArchivedConversationsAndMainOpensOnWelcome() async throws {
		try await seedV1Chat(
			firstChat, asking: "How was my week?", reply: "Two rides.", hoursAgo: 48)
		try await seedV1Chat(
			secondChat, asking: "Is Thursday still on?", reply: "Yes, keep it.", hoursAgo: 2)
		let coach = await coach()
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .welcome)
		let archived = try await coach.history()
		#expect(archived.map(\.reason) == [.earlierChat, .earlierChat])
		#expect(archived.map(\.id.rawValue) == [secondChat.rawValue, firstChat.rawValue])
		#expect(
			archived.map(\.firstQuestion)
				== ["Is Thursday still on?", "How was my week?"])
		var opened: [ArchivedConversation] = []
		for summary in archived {
			opened.append(try #require(try await coach.archivedConversation(summary.id)))
		}
		#expect(
			opened.map { $0.turns.compactMap { replyText($0.state) } } == [
				["Yes, keep it."], ["Two rides."],
			])
		#expect(archived.map(\.startedOn) == ["1998-06-13", "1998-06-13"])
		#expect(try await store.fetch(RecordQuery(scope: .everySynced)).records.count == 4)
		#expect(transport.requests.isEmpty)
	}

	@Test func legacyAssistantTrimKeepsTheFirstVisibleQuestionAndReply() async throws {
		let boundary = fixedUlid(40)
		let bodies: [(Int, CivilDate, RecordBody)] = [
			(10, "1998-06-11", legacyUser(chatId: .main, text: "Hidden question")),
			(11, "1998-06-11", legacyReply(chatId: .main, text: "Kept first reply")),
			(20, "1998-06-12", legacyUser(chatId: .main, text: "Visible question")),
			(21, "1998-06-12", legacyReply(chatId: .main, text: "Kept second reply")),
			(
				30, "1998-06-12",
				.legacy(.windowStartV1(chatId: .main, firstIncludedUlid: fixedUlid(11)))
			),
			(
				40, "1998-06-13",
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: boundary,
							reason: .reset(ResetID(ulid: boundary)))))
			),
		]
		try await seed(
			store,
			bodies.map { index, date, body in
				storedRecord(
					device: store.deviceId, wall: Int64(index), date: date,
					ulid: fixedUlid(index), body: body)
			})
		let coach = await coach()
		let history = try await coach.history()
		#expect(history.count == 1)
		let summary = try #require(history.first)
		#expect(summary.firstQuestion == "Visible question")
		#expect(summary.startedOn == "1998-06-11")
		#expect(summary.reason == .newConversation)
		let opened = try #require(try await coach.archivedConversation(summary.id))
		#expect(opened.turns.map(\.athleteText) == [nil, "Visible question"])
		#expect(
			opened.turns.compactMap { replyText($0.state) } == [
				"Kept first reply", "Kept second reply",
			])
		#expect(opened.startedOn == summary.startedOn)
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
								chatId: .main, messageUlids: [seeded[0].user, seeded[0].reply]))))
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

		@Test func fiftyArchivedConversationsReadEachRowOnce() async throws {
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
										reason: .reset(ResetID(ulid: boundary)))))),
					])
			}
			let log = BatchRecordingLog(inner: store)
			let coach = await makeCoach(
				transport: FakeModelTransport(), store: log, clock: clock, consent: false)
			let archived = try await coach.history()
			#expect(archived.count == 50)
			#expect(archived.first?.firstQuestion == "Archived 50")
			#expect(log.reads.count == 1)
			#expect(log.fetchedRecordCount == 100)
		}
	}
}
