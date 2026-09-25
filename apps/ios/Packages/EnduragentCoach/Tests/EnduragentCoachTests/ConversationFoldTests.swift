import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationFoldTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")

	@Test func legacyAssistantMessageFoldsAsRepliedSettlement() throws {
		let question = storedRecord(
			device: phoneA, wall: 1, ulid: ulid(1), body: legacyUser(chatId: .main, text: "week?"))
		let reply = storedRecord(
			device: phoneA, wall: 2, ulid: ulid(2), body: legacyReply(chatId: .main, text: "Two rides."))
		let second = storedRecord(
			device: phoneA, wall: 3, ulid: ulid(3), body: legacyUser(chatId: .main, text: "again?"))
		let secondReply = storedRecord(
			device: phoneA, wall: 4, ulid: ulid(4), body: legacyReply(chatId: .main, text: "Still two."))
		let conversation = ConversationFold.fold(
			chat: .main, synced: [secondReply, reply, second, question], device: phoneA)
		let turns = conversation.current.turns
		#expect(turns.map(\.turn) == [TurnID(ulid: ulid(1)), TurnID(ulid: ulid(3))])
		let first = try #require(turns.first)
		#expect(first.fragments.map(\.draft) == [nil])
		#expect(first.latestSettlement?.settlement == .replied(.model("Two rides."), lineage: ReplyLineage(templateHash: "t", assembledHash: "a")))
		#expect(
			conversation.current.messages.map(\.text) == ["week?", "Two rides.", "again?", "Still two."])
		#expect(conversation.current.messages.map(\.role) == [.user, .assistant, .user, .assistant])
	}

	@Test func settledTurnsInterleaveWithLegacyOnesByClock() throws {
		let turn = TurnID(ulid: ulid(5))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1), body: legacyUser(chatId: .main, text: "old")),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2), body: legacyReply(chatId: .main, text: "old reply")),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				body: .synced(sampleUser(chatId: .main, text: "new", turn: turn))),
			storedRecord(
				device: phoneA, wall: 4, ulid: ulid(4),
				body: .synced(sampleReply(chatId: .main, turn: turn, text: "new reply"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.current.messages.map(\.text) == ["old", "old reply", "new", "new reply"])
		#expect(conversation.lastExchange == .at(Date(timeIntervalSince1970: 0.004)))
	}

	@Test func resetBoundaryFromAnyDeviceSplitsSegments() throws {
		let before = TurnID(ulid: ulid(1))
		let after = TurnID(ulid: ulid(4))
		let resetId = ResetID(ulid: ulid(3))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				body: .synced(sampleUser(chatId: .main, text: "before", turn: before))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				body: .synced(sampleReply(chatId: .main, turn: before, text: "before reply"))),
			storedRecord(
				device: phoneB, wall: 3, ulid: ulid(3),
				body: .synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: ulid(3),
							reason: .reset(.explicit(resetId)))))),
			storedRecord(
				device: phoneA, wall: 4, ulid: ulid(4),
				body: .synced(sampleUser(chatId: .main, text: "after", turn: after))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.segments.count == 2)
		#expect(conversation.segments[0].openedBy == .chatStart)
		#expect(conversation.segments[0].messages.map(\.text) == ["before", "before reply"])
		#expect(conversation.current.openedBy == .reset(.explicit(resetId)))
		#expect(conversation.current.id == SegmentID(boundary: ulid(3)))
		#expect(conversation.current.messages.map(\.text) == ["after"])
		#expect(conversation.current.promptHistory(excluding: after).messages.isEmpty)
	}

	@Test func trimWindowFromAnotherDeviceIsIgnored() throws {
		let first = TurnID(ulid: ulid(1))
		let second = TurnID(ulid: ulid(3))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				body: .synced(sampleUser(chatId: .main, text: "first", turn: first))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				body: .synced(sampleReply(chatId: .main, turn: first, text: "first reply"))),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3),
				body: .synced(sampleUser(chatId: .main, text: "second", turn: second))),
			storedRecord(
				device: phoneB, wall: 4, ulid: ulid(4),
				body: .synced(
					.windowStart(
						WindowStartBody(chatId: .main, firstIncludedUlid: ulid(3), reason: .trim)))),
		]
		let onA = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(onA.current.promptWindow.firstIncluded == nil)
		#expect(onA.current.promptHistory(excluding: nil).messages.map(\.text) == ["first", "first reply", "second"])
		let onB = ConversationFold.fold(chat: .main, synced: records, device: phoneB)
		#expect(onB.current.promptWindow.firstIncluded == ulid(3))
		#expect(onB.current.promptHistory(excluding: nil).messages.map(\.text) == ["second"])
		#expect(onB.current.messages.map(\.text) == ["first", "first reply", "second"])
		#expect(onB.segments.count == 1)
	}

	@Test func v1WindowStartFoldsAsTrimAndHidesNothingFromTheTranscript() throws {
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1), body: legacyUser(chatId: .main, text: "old")),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2), body: legacyReply(chatId: .main, text: "old reply")),
			storedRecord(
				device: phoneA, wall: 3, ulid: ulid(3), body: legacyUser(chatId: .main, text: "kept")),
			storedRecord(
				device: phoneA, wall: 4, ulid: ulid(4),
				body: .legacy(.windowStartV1(chatId: .main, firstIncludedUlid: ulid(3)))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.segments.count == 1)
		#expect(conversation.current.messages.map(\.text) == ["old", "old reply", "kept"])
		let history = conversation.current.promptHistory(excluding: nil)
		#expect(history.messages.map(\.text) == ["kept"])
		#expect(history.ulids == [ulid(3)])
	}

	@Test func messagesForUlidsResolveFragmentsAndSettlements() throws {
		let turn = TurnID(ulid: ulid(1))
		let records = [
			storedRecord(
				device: phoneA, wall: 1, ulid: ulid(1),
				body: .synced(sampleUser(chatId: .main, text: "q", turn: turn))),
			storedRecord(
				device: phoneA, wall: 2, ulid: ulid(2),
				body: .synced(sampleReply(chatId: .main, turn: turn, text: "a"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.messages(for: [ulid(2), ulid(1), ulid(9)]).map(\.text) == ["a", "q"])
	}

	private func ulid(_ offset: Int) -> ULID {
		fixedUlid(offset)
	}
}
