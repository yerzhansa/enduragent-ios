import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct HistoryTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())

	func coach() async -> Coach {
		await makeCoach(transport: transport, store: store, clock: clock)
	}

	func seedArchives() async throws {
		for index in 1...2 {
			let turn = TurnID(ulid: fixedUlid(index * 10))
			let boundary = fixedUlid(index * 10 + 2)
			try await seed(
				store,
				[
					storedRecord(
						device: store.deviceId, wall: Int64(index * 10), ulid: turn.ulid,
						body: .synced(
							sampleUser(chatId: .main, text: "Question \(index)", turn: turn))),
					storedRecord(
						device: store.deviceId, wall: Int64(index * 10 + 1),
						ulid: fixedUlid(index * 10 + 1),
						body: .synced(
							sampleReply(chatId: .main, turn: turn, text: "Archived reply \(index)"))
					),
					storedRecord(
						device: store.deviceId, wall: Int64(index * 10 + 2), ulid: boundary,
						body: .synced(
							.windowStart(
								WindowStartBody(
									chatId: .main, firstIncludedUlid: boundary,
									reason: .reset(ResetID(ulid: boundary)))))),
				])
		}
	}

	@Test func historyListCarriesNoReplyText() async throws {
		try await seedArchives()
		let history = try await coach().history()
		#expect(history.count == 2)
		#expect(history.map(\.firstQuestion) == ["Question 2", "Question 1"])
		#expect(history.map(\.startedOn) == ["1998-06-13", "1998-06-13"])
		#expect(history.map(\.reason) == [.newConversation, .newConversation])
		#expect(!String(reflecting: history).contains("Archived reply"))
		#expect(transport.requests.isEmpty)
	}

	@Test func openingAnArchiveShowsOnlyItsReplies() async throws {
		try await seedArchives()
		let coach = await coach()
		let summary = try #require(try await coach.history().last)
		let archived = try #require(try await coach.archivedConversation(summary.id))
		#expect(archived.id == summary.id)
		#expect(archived.startedOn == summary.startedOn)
		#expect(archived.reason == summary.reason)
		#expect(archived.turns.map(\.athleteText) == ["Question 1"])
		#expect(archived.turns.compactMap { replyText($0.state) } == ["Archived reply 1"])
		#expect(transport.requests.isEmpty)
	}

	@Test func historyReportsAStorageFailure() async throws {
		try await seedArchives()
		let coach = await coach()
		let history = try await coach.history()
		let ref = try #require(history.first?.id)
		store.failFetches = true
		await #expect(throws: HistoryUnavailable.storageUnavailable) {
			try await coach.history()
		}
		await #expect(throws: HistoryUnavailable.storageUnavailable) {
			try await coach.archivedConversation(ref)
		}
	}

	@Test func openingAnUnknownOrCurrentSegmentReturnsNoArchive() async throws {
		try await seedArchives()
		let coach = await coach()
		for boundary in [fixedUlid(22), fixedUlid(99)] {
			let ref = ArchivedConversationRef(chat: .main, segment: SegmentID(boundary: boundary))
			#expect(try await coach.archivedConversation(ref) == nil)
		}
	}
}
