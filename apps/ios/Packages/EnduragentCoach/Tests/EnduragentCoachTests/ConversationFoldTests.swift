import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationFoldTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")

	@Test func legacyAssistantMessageFoldsAsRepliedSettlement() throws {
		let question = storedRecord(
			device: phoneA, wall: 1, ulid: ulid(1), account: testConnection.account,
			body: legacyUser(chatId: .main, text: "week?"))
		let reply = storedRecord(
			device: phoneA, wall: 2, ulid: ulid(2),
			account: testConnection.account, body: legacyReply(chatId: .main, text: "Two rides."))
		let second = storedRecord(
			device: phoneA, wall: 3, ulid: ulid(3), account: testConnection.account,
			body: legacyUser(chatId: .main, text: "again?"))
		let secondReply = storedRecord(
			device: phoneA, wall: 4, ulid: ulid(4),
			account: testConnection.account, body: legacyReply(chatId: .main, text: "Still two."))
		let conversation = ConversationFold.fold(
			chat: .main, synced: [secondReply, reply, second, question], device: phoneA)
		let turns = conversation.current.turns
		#expect(turns.map(\.turn) == [TurnID(ulid: ulid(1)), TurnID(ulid: ulid(3))])
		let first = try #require(turns.first)
		#expect(first.fragments.map(\.draft) == [nil])
		#expect(
			first.latestSettlement?.settlement
				== .replied(
					.model("Two rides."),
					lineage: ReplyLineage(templateHash: "t", assembledHash: "a")))
		#expect(
			conversation.current.messages.map(\.text) == [
				"week?", "Two rides.", "again?", "Still two.",
			])
		#expect(
			conversation.current.messages.map(\.author) == [
				.athlete(sent: ulid(1).time, timeZone: amsterdamZone), .coach,
				.athlete(sent: ulid(3).time, timeZone: amsterdamZone), .coach,
			])
	}

	@Test func settledTurnsInterleaveWithLegacyOnesByClock() throws {
		let turn = TurnID(ulid: ulid(5))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1), account: testConnection.account,
				body: legacyUser(chatId: .main, text: "old")
			),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account, body: legacyReply(chatId: .main, text: "old reply")
			),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "new", turn: turn))),
			storedRecord(
				device: phoneA, wall: 4, ulid: ulid(4),
				account: testConnection.account,
				body: .synced(sampleReply(chatId: .main, turn: turn, text: "new reply"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(
			conversation.current.messages.map(\.text) == ["old", "old reply", "new", "new reply"])
	}

	@Test func trimWindowFromAnotherDeviceIsIgnored() throws {
		let first = TurnID(ulid: ulid(1))
		let second = TurnID(ulid: ulid(3))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "first", turn: first))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account,
				body: .synced(sampleReply(chatId: .main, turn: first, text: "first reply"))),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "second", turn: second))),
			storedRecord(
				device: phoneB, wall: 4, ulid: ulid(4),
				account: testConnection.account,
				body: .synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: ulid(3), reason: .trim,
							droppedMessageUlids: [ulid(1), ulid(2)])))),
			storedRecord(
				device: phoneA, wall: 5, ulid: ulid(5),
				account: testConnection.account,
				body: .synced(sampleReply(chatId: .main, turn: second, text: "second reply"))),
		]
		let onA = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(onA.current.promptWindows.values.first?.trim == nil)
		#expect(
			onA.current.promptHistory(
				excluding: nil, for: testConnection.account, device: phoneA, using: onA.ownership
			).messages.map(\.text) == [
				"first", "first reply", "second", "second reply",
			])
		let onB = ConversationFold.fold(chat: .main, synced: records, device: phoneB)
		#expect(
			onB.current.promptWindows.values.first?.trim
				== .init(messageUlids: [ulid(1), ulid(2)], opened: ulid(4)))
		#expect(
			onB.current.promptHistory(
				excluding: nil, for: testConnection.account, device: phoneB, using: onB.ownership
			).messages.map(\.text) == [
				"second", "second reply",
			])
		#expect(
			onB.current.messages.map(\.text) == ["first", "first reply", "second", "second reply"])
		#expect(onB.segments.count == 1)
	}

	@Test func v1TrimWindowHidesEarlierRowsFromEveryDeviceAsTrunkDid() throws {
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1), account: testConnection.account,
				body: legacyUser(chatId: .main, text: "old")
			),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account, body: legacyReply(chatId: .main, text: "old reply")
			),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				account: testConnection.account, body: legacyUser(chatId: .main, text: "kept")),
			storedRecord(
				device: phoneB, wall: 4, ulid: ulid(4),
				account: testConnection.account,
				body: .legacy(.windowStartV1(chatId: .main, firstIncludedUlid: ulid(2)))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.segments.count == 1)
		#expect(conversation.current.messages.map(\.text) == ["old reply", "kept"])
		let history = conversation.current.promptHistory(
			excluding: nil, for: testConnection.account, device: phoneA,
			using: conversation.ownership)
		#expect(history.messages.map(\.text) == ["old reply", "kept"])
		#expect(history.ulids == [ulid(2), ulid(3)])
	}

	@Test func v1BoundarySplitsTheDaysAfterAnUpgrade() throws {
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				account: testConnection.account, body: legacyUser(chatId: .main, text: "day one")),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account,
				body: legacyReply(chatId: .main, text: "day one reply")),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(4),
				account: testConnection.account,
				body: .legacy(.windowStartV1(chatId: .main, firstIncludedUlid: ulid(3)))),
			storedRecord(
				device: phoneA, wall: 4, ulid: ulid(5),
				account: testConnection.account, body: legacyUser(chatId: .main, text: "day two")),
			storedRecord(
				device: phoneA, wall: 5, ulid: ulid(6),
				account: testConnection.account,
				body: legacyReply(chatId: .main, text: "day two reply")),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneB)
		#expect(conversation.segments.count == 2)
		#expect(conversation.segments[0].messages.map(\.text) == ["day one", "day one reply"])
		#expect(conversation.current.openedBy == .legacyBoundary)
		#expect(conversation.current.id == SegmentID(boundary: ulid(3)))
		#expect(conversation.current.messages.map(\.text) == ["day two", "day two reply"])
	}

	@Test func legacyReplyAttachesToItsOwnDevicesQuestion() throws {
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				account: testConnection.account, body: legacyUser(chatId: .main, text: "a asks")),
			storedRecord(
				device: phoneB, wall: 2, ulid: ulid(2),
				account: testConnection.account, body: legacyUser(chatId: .main, text: "b asks")),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				account: testConnection.account,
				body: legacyReply(chatId: .main, text: "a answered")),
			storedRecord(
				device: phoneB, wall: 4, ulid: ulid(4),
				account: testConnection.account,
				body: legacyReply(chatId: .main, text: "b answered")),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(
			conversation.current.messages.map(\.text) == [
				"a asks", "a answered", "b asks", "b answered",
			])
		let turns = conversation.current.turns
		#expect(turns.map(\.origin) == [phoneA, phoneB])
		#expect(turns.map { $0.settlements.count } == [1, 1])
	}

	@Test func unsettledFailedAndStoppedTurnsAreNotPromptHistory() throws {
		let answered = TurnID(ulid: ulid(1))
		let pending = TurnID(ulid: ulid(3))
		let failed = TurnID(ulid: ulid(4))
		let stopped = TurnID(ulid: ulid(6))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "answered", turn: answered))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account,
				body: .synced(sampleReply(chatId: .main, turn: answered, text: "reply"))),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "pending", turn: pending))),
			storedRecord(
				device: phoneA, wall: 4, ulid: ulid(4),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "failed", turn: failed))),
			storedRecord(
				device: phoneA, wall: 5, ulid: ulid(5),
				account: testConnection.account,
				body: .synced(
					.turnSettled(
						TurnSettledBody(
							chatId: .main, turn: failed, attempt: AttemptID(ulid: ulid(5)),
							settlement: .failed(.model(.contextOverflow), saved: .none))))),
			storedRecord(
				device: phoneA, wall: 6, ulid: ulid(6),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "stopped", turn: stopped))),
			storedRecord(
				device: phoneA, wall: 7, ulid: ulid(7),
				account: testConnection.account,
				body: .synced(
					.turnSettled(
						TurnSettledBody(
							chatId: .main, turn: stopped, attempt: AttemptID(ulid: ulid(7)),
							settlement: .interrupted(
								partial: "half an", cause: .athleteStopped, saved: .none))))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.current.turns.map(\.turn) == [answered, pending, failed, stopped])
		#expect(
			conversation.current.promptHistory(
				excluding: nil, for: testConnection.account, device: phoneA,
				using: conversation.ownership
			).messages.map(\.text) == [
				"answered", "reply", "stopped", "half an",
			])
	}

	@Test func messagesForUlidsResolveFragmentsAndSettlements() throws {
		let turn = TurnID(ulid: ulid(1))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "q", turn: turn))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account,
				body: .synced(sampleReply(chatId: .main, turn: turn, text: "a"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.messages(for: [ulid(2), ulid(1), ulid(9)]).map(\.text) == ["a", "q"])
	}

	@Test func latestSummaryAtOrAfterThisDevicesWindowOpensPromptHistory() throws {
		let turn = TurnID(ulid: ulid(1))
		let kept = TurnID(ulid: ulid(3))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "dropped", turn: turn))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account,
				body: .synced(sampleReply(chatId: .main, turn: turn, text: "dropped reply"))),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				account: testConnection.account,
				body: .synced(sampleUser(chatId: .main, text: "kept", turn: kept))),
			storedRecord(
				device: phoneA, wall: 4, ulid: ulid(4),
				account: testConnection.account, body: .synced(summary("stale, before the window"))),
			storedRecord(
				device: phoneA, wall: 5, ulid: ulid(5),
				account: testConnection.account,
				body: .synced(
					.windowStart(
						WindowStartBody(chatId: .main, firstIncludedUlid: ulid(3), reason: .trim)))),
			storedRecord(
				device: phoneA, wall: 6, ulid: ulid(6), account: testConnection.account,
				body: .synced(summary("first"))),
			storedRecord(
				device: phoneA, wall: 7, ulid: ulid(7), account: testConnection.account,
				body: .synced(summary("latest"))),
			storedRecord(
				device: phoneB, wall: 8, ulid: ulid(8), account: testConnection.account,
				body: .synced(summary("phone b"))),
			storedRecord(
				device: phoneA, wall: 9, ulid: ulid(9),
				account: testConnection.account,
				body: .synced(sampleReply(chatId: .main, turn: kept, text: "kept reply"))),
		]
		let onA = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		let history = onA.current.promptHistory(
			excluding: nil, for: testConnection.account, device: phoneA, using: onA.ownership)
		#expect(history.summary == "latest")
		#expect(history.messages.map(\.text) == ["kept", "kept reply"])
		let onB = ConversationFold.fold(chat: .main, synced: records, device: phoneB)
		#expect(
			onB.current.promptHistory(
				excluding: nil, for: testConnection.account, device: phoneB, using: onB.ownership
			).summary == "phone b")
	}

	@Test func aWindowWithoutASummaryAfterItDropsTheOlderSummary() throws {
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1), account: testConnection.account,
				body: .synced(summary("old"))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				account: testConnection.account,
				body: .synced(
					.windowStart(
						WindowStartBody(chatId: .main, firstIncludedUlid: ulid(2), reason: .trim)))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(
			conversation.current.promptHistory(
				excluding: nil, for: testConnection.account, device: phoneA,
				using: conversation.ownership
			).summary == nil)
	}

	private func summary(_ markdown: String) -> SyncedRecordBody {
		.compactionSummary(CompactionSummaryBody(chatId: .main, markdown: markdown))
	}

	private func ulid(_ offset: Int) -> ULID {
		fixedUlid(offset)
	}
}
