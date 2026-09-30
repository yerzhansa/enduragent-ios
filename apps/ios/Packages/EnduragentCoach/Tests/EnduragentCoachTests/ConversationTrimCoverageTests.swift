import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConversationTrimCoverageTests {
	let local = DeviceID(rawValue: "local-phone")
	let remote = DeviceID(rawValue: "remote-phone")

	@Test func successiveTrimsCoverOnlyTheirListedMessages() throws {
		let first = TurnID(ulid: fixedUlid(1))
		let second = TurnID(ulid: fixedUlid(3))
		let kept = TurnID(ulid: fixedUlid(5))
		let records = [
			record(1, device: remote, sampleUser(chatId: .main, text: "First", turn: first)),
			record(2, device: remote, sampleReply(chatId: .main, turn: first, text: "First reply")),
			record(3, device: local, sampleUser(chatId: .main, text: "Second", turn: second)),
			record(
				4, device: local, sampleReply(chatId: .main, turn: second, text: "Second reply")),
			record(5, device: remote, sampleUser(chatId: .main, text: "Kept", turn: kept)),
			record(6, device: remote, sampleReply(chatId: .main, turn: kept, text: "Kept reply")),
			record(
				7, device: local,
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: fixedUlid(3), reason: .trim,
						droppedMessageUlids: [fixedUlid(1), fixedUlid(2)]))),
			record(
				8, device: local,
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: fixedUlid(5), reason: .trim,
						droppedMessageUlids: [fixedUlid(3), fixedUlid(4)]))),
			record(
				9, device: local,
				.compactionSummary(
					CompactionSummaryBody(chatId: .main, markdown: "First and second."))),
		]
		var live = Conversation(chat: .main, segments: [])
		for record in records { live.apply([record], device: local) }
		let reloaded = ConversationFold.fold(chat: .main, synced: records, device: local)
		#expect(live == reloaded)
		#expect(
			live.current.promptHistory(excluding: nil).messages.map(\.text) == [
				"Kept", "Kept reply",
			])
		let later = record(
			10, device: remote, sampleReply(chatId: .main, turn: first, text: "Later reply"))
		live.apply([later], device: local)
		#expect(
			live.current.promptHistory(excluding: nil).messages.map(\.text)
				== ["First", "Later reply", "Kept", "Kept reply"])
		#expect(
			live == ConversationFold.fold(chat: .main, synced: records + [later], device: local))
	}

	@Test func aResetQueuedBeforeATrimCommitMatchesReload() {
		let turn = TurnID(ulid: fixedUlid(1))
		let records = [
			record(1, device: local, sampleUser(chatId: .main, text: "Before", turn: turn)),
			record(2, device: local, sampleReply(chatId: .main, turn: turn, text: "Before reply")),
			record(
				4, device: local,
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: fixedUlid(3), reason: .trim,
						droppedMessageUlids: [fixedUlid(1), fixedUlid(2)]))),
			record(
				5, device: local,
				.compactionSummary(
					CompactionSummaryBody(chatId: .main, markdown: "Before reset."))),
			record(
				6, device: local,
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: fixedUlid(3),
						reason: .reset(ResetID(ulid: fixedUlid(3)))))),
		]
		var live = Conversation(chat: .main, segments: [])
		for record in records { live.apply([record], device: local) }
		let reloaded = ConversationFold.fold(chat: .main, synced: records, device: local)
		#expect(live == reloaded)
		#expect(live.current.promptHistory(excluding: nil).summary == nil)
	}

	@Test func oldTrimRetainsRemoteTurnsWithoutRecordedCoverage() {
		let first = TurnID(ulid: fixedUlid(1))
		let records = [
			record(1, device: remote, sampleUser(chatId: .main, text: "Remote", turn: first)),
			record(
				3, device: remote, sampleReply(chatId: .main, turn: first, text: "Remote reply")),
			record(
				4, device: local,
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: fixedUlid(2), reason: .trim))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: local)
		#expect(
			conversation.current.promptHistory(excluding: nil).messages.map(\.text)
				== ["Remote", "Remote reply"])
	}

	@Test func trimCoverageSurvivesStorageAndOlderPayloadsDecode() throws {
		let body = RecordBody.synced(
			.windowStart(
				WindowStartBody(
					chatId: .main, firstIncludedUlid: fixedUlid(3), reason: .trim,
					droppedMessageUlids: [fixedUlid(1), fixedUlid(2)])))
		let encoded = try RecordCodec.encode(body)
		let golden =
			#"{"chatId":"main","droppedMessageUlids":["\#(fixedUlid(1).rawValue)","\#(fixedUlid(2).rawValue)"],"firstIncludedUlid":"\#(fixedUlid(3).rawValue)","reason":"trim"}"#
		#expect(encoded.version == 2)
		#expect(encoded.data == Data(golden.utf8))
		#expect(
			RecordCodec.decode(
				kind: "windowStart", version: encoded.version, data: encoded.data,
				civilDate: "1998-06-13", ulid: fixedUlid(4).rawValue) == .success(body))
		let older = Data(
			#"{"chatId":"main","firstIncludedUlid":"\#(fixedUlid(3).rawValue)","reason":"trim"}"#
				.utf8)
		#expect(
			RecordCodec.decode(
				kind: "windowStart", version: 2, data: older,
				civilDate: "1998-06-13", ulid: fixedUlid(4).rawValue)
				== .success(
					.synced(
						.windowStart(
							WindowStartBody(
								chatId: .main, firstIncludedUlid: fixedUlid(3), reason: .trim)))))
	}

	private func record(_ index: Int, device: DeviceID, _ body: SyncedRecordBody) -> AthleteRecord {
		storedRecord(
			device: device, wall: Int64(index), ulid: fixedUlid(index), body: .synced(body))
	}
}
