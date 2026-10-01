import Foundation

package enum ConversationFold {
	package static let syncedScope: RecordQuery.Scope = .synced(
		[
			.userMessage, .turnSettled, .windowStart, .compactionSummary, .reviewApplied,
			.reviewWrite,
		],
		includeLegacy: [.userMessage, .assistantMessage, .windowStart]
	)

	package static let localScope: RecordQuery.Scope = .deviceLocal([
		.turnClaim, .replyObserved, .pendingSettlement,
	])

	package static func fold(
		chat: ChatID, synced: [AthleteRecord], local: [AthleteRecord] = [], device: DeviceID
	) -> Conversation {
		var conversation = Conversation(chat: chat, segments: [])
		conversation.apply(synced + local, device: device)
		return conversation
	}
}

extension Ledger {
	package func conversation(_ chat: ChatID) async throws(LedgerFailure) -> Conversation {
		let records = try await conversationRecords(chat)
		return ConversationFold.fold(chat: chat, synced: records, device: deviceId)
	}

	func conversationRecords(_ chat: ChatID) async throws(LedgerFailure) -> [AthleteRecord] {
		let synced = try await read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chat))
		let local = try await read(RecordQuery(scope: ConversationFold.localScope, chatId: chat))
		return synced.records + local.records
	}
}

package struct Conversation: Sendable, Equatable {
	package let chat: ChatID
	package var segments: [Segment]
	package var legacyMessageUlids: Set<ULID> = []
	var appliedRecordIDs: Set<ULID> = []

	package var current: Segment {
		guard let last = segments.last else {
			return Segment(id: SegmentID(boundary: nil), openedBy: .chatStart)
		}
		return last
	}

	package func turn(_ id: TurnID) -> TurnFacts? {
		guard let position = position(of: id) else { return nil }
		return segments[position.segment].turns[position.turn]
	}

	package func turn(withDraft draft: DraftID) -> TurnFacts? {
		for segment in segments {
			for facts in segment.turns where facts.fragments.contains(where: { $0.draft == draft })
			{
				return facts
			}
		}
		return nil
	}

	private func position(of id: TurnID) -> (segment: Int, turn: Int)? {
		for (segmentIndex, segment) in segments.enumerated() {
			if let turnIndex = segment.turns.firstIndex(where: { $0.turn == id }) {
				return (segmentIndex, turnIndex)
			}
		}
		return nil
	}

	@discardableResult
	package mutating func observeInMemory(_ turn: TurnID, attempt: AttemptID, device: DeviceID)
		-> AthleteRecord?
	{
		applyInMemory(
			.deviceLocal(
				.replyObserved(ReplyObservedBody(chatId: chat, turn: turn, attempt: attempt))),
			turn: turn, attempt: attempt, ulid: attempt.ulid, now: attempt.ulid.time, device: device
		)
	}

	@discardableResult
	package mutating func settleInMemory(
		_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement, ulid: ULID, now: Date,
		device: DeviceID
	) -> AthleteRecord? {
		applyInMemory(
			.synced(
				.turnSettled(
					TurnSettledBody(
						chatId: chat, turn: turn, attempt: attempt, settlement: settlement))),
			turn: turn, attempt: attempt, ulid: ulid, now: now, device: device)
	}

	private mutating func applyInMemory(
		_ body: RecordBody, turn id: TurnID, attempt: AttemptID, ulid: ULID, now: Date,
		device: DeviceID
	) -> AthleteRecord? {
		guard let facts = turn(id) else { return nil }
		let last =
			(facts.fragments.map(\.hlc) + facts.claims.map(\.hlc)
			+ facts.settlements.map(\.hlc)).max()
		let record = AthleteRecord(
			ulid: ulid, deviceId: device,
			hlc: HybridLogicalClock.tick(now: now, deviceId: device, last: last),
			timeZone: .gmt, civilDate: CivilDate(date: now, timeZone: .gmt),
			cause: .operation(.turn(id), attempt), account: .unconnected, body: body)
		apply([record], device: device)
		return record
	}
}
