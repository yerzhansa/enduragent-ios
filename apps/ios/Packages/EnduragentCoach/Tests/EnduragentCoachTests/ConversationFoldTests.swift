import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationFoldTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")

	@Test func legacyAssistantMessageFoldsAsRepliedSettlement() throws {
		let question = foldRow(1, phoneA, legacyUser(chatId: .main, text: "week?"))
		let reply = foldRow(2, phoneA, legacyReply(chatId: .main, text: "Two rides."))
		let second = foldRow(3, phoneA, legacyUser(chatId: .main, text: "again?"))
		let secondReply = foldRow(4, phoneA, legacyReply(chatId: .main, text: "Still two."))
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
			foldRow(
				1, phoneA, legacyUser(chatId: .main, text: "old")
			),
			foldRow(
				2, phoneA, legacyReply(chatId: .main, text: "old reply")
			),
			foldRow(3, phoneA, .synced(sampleUser(chatId: .main, text: "new", turn: turn))),
			foldRow(4, phoneA, .synced(sampleReply(chatId: .main, turn: turn, text: "new reply"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(
			conversation.current.messages.map(\.text) == ["old", "old reply", "new", "new reply"])
	}

	@Test func trimWindowFromAnotherDeviceIsIgnored() throws {
		let first = TurnID(ulid: ulid(1))
		let second = TurnID(ulid: ulid(3))
		let records = [
			foldRow(1, phoneA, .synced(sampleUser(chatId: .main, text: "first", turn: first))),
			foldRow(
				2, phoneA, .synced(sampleReply(chatId: .main, turn: first, text: "first reply"))),
			foldRow(3, phoneA, .synced(sampleUser(chatId: .main, text: "second", turn: second))),
			foldRow(
				4, phoneB,
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: ulid(3), reason: .trim,
							droppedMessageUlids: [ulid(1), ulid(2)])))),
			foldRow(
				5, phoneA, .synced(sampleReply(chatId: .main, turn: second, text: "second reply"))),
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
			foldRow(
				1, phoneA, legacyUser(chatId: .main, text: "old")
			),
			foldRow(
				2, phoneA, legacyReply(chatId: .main, text: "old reply")
			),
			foldRow(3, phoneA, legacyUser(chatId: .main, text: "kept")),
			foldRow(4, phoneB, .legacy(.windowStartV1(chatId: .main, firstIncludedUlid: ulid(2)))),
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
			foldRow(1, phoneA, legacyUser(chatId: .main, text: "day one")),
			foldRow(2, phoneA, legacyReply(chatId: .main, text: "day one reply")),
			foldRow(
				4, wall: 3, phoneA,
				.legacy(.windowStartV1(chatId: .main, firstIncludedUlid: ulid(3)))),
			foldRow(5, wall: 4, phoneA, legacyUser(chatId: .main, text: "day two")),
			foldRow(6, wall: 5, phoneA, legacyReply(chatId: .main, text: "day two reply")),
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
			foldRow(1, phoneA, legacyUser(chatId: .main, text: "a asks")),
			foldRow(2, phoneB, legacyUser(chatId: .main, text: "b asks")),
			foldRow(3, phoneA, legacyReply(chatId: .main, text: "a answered")),
			foldRow(4, phoneB, legacyReply(chatId: .main, text: "b answered")),
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
			foldRow(
				1, phoneA, .synced(sampleUser(chatId: .main, text: "answered", turn: answered))),
			foldRow(2, phoneA, .synced(sampleReply(chatId: .main, turn: answered, text: "reply"))),
			foldRow(3, phoneA, .synced(sampleUser(chatId: .main, text: "pending", turn: pending))),
			foldRow(4, phoneA, .synced(sampleUser(chatId: .main, text: "failed", turn: failed))),
			foldRow(
				5, phoneA,
				.synced(
					.turnSettled(
						TurnSettledBody(
							chatId: .main, turn: failed, attempt: AttemptID(ulid: ulid(5)),
							settlement: .failed(.model(.contextOverflow), saved: .none))))),
			foldRow(6, phoneA, .synced(sampleUser(chatId: .main, text: "stopped", turn: stopped))),
			foldRow(
				7, phoneA,
				.synced(
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
			foldRow(1, phoneA, .synced(sampleUser(chatId: .main, text: "q", turn: turn))),
			foldRow(2, phoneA, .synced(sampleReply(chatId: .main, turn: turn, text: "a"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.messages(for: [ulid(2), ulid(1), ulid(9)]).map(\.text) == ["a", "q"])
	}

	@Test func latestSummaryAtOrAfterThisDevicesWindowOpensPromptHistory() throws {
		let turn = TurnID(ulid: ulid(1))
		let kept = TurnID(ulid: ulid(3))
		let records = [
			foldRow(1, phoneA, .synced(sampleUser(chatId: .main, text: "dropped", turn: turn))),
			foldRow(
				2, phoneA, .synced(sampleReply(chatId: .main, turn: turn, text: "dropped reply"))),
			foldRow(3, phoneA, .synced(sampleUser(chatId: .main, text: "kept", turn: kept))),
			foldRow(4, phoneA, .synced(summary("stale, before the window"))),
			foldRow(
				5, phoneA,
				.synced(
					.windowStart(
						WindowStartBody(chatId: .main, firstIncludedUlid: ulid(3), reason: .trim)))),
			foldRow(6, phoneA, .synced(summary("first"))),
			foldRow(7, phoneA, .synced(summary("latest"))),
			foldRow(8, phoneB, .synced(summary("phone b"))),
			foldRow(9, phoneA, .synced(sampleReply(chatId: .main, turn: kept, text: "kept reply"))),
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
			foldRow(1, phoneA, .synced(summary("old"))),
			foldRow(
				2, phoneA,
				.synced(
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

func foldRow(_ ulid: Int, wall: Int64? = nil, _ device: DeviceID, _ body: RecordBody)
	-> AthleteRecord
{
	storedRecord(
		device: device, wall: wall ?? Int64(ulid), ulid: fixedUlid(ulid),
		account: testConnection.account, body: body)
}
