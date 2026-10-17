import Foundation

extension Conversation {
	func hasLocalWork(on device: DeviceID) -> Bool {
		segments.contains { segment in
			segment.turns.contains { turn in
				turn.origin == device && !turn.legacy && turn.latestSettlement == nil
			}
		}
	}
}

extension Ledger {
	func hasLocalWork(
		in chat: ChatID? = nil, excluding excluded: Set<ChatID> = []
	) async throws(LedgerFailure) -> Bool {
		let synced = try await read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chat)
		).records
		let local = try await read(
			RecordQuery(
				scope: .deviceLocal([.turnClaim, .replyObserved, .flushPending, .flushSettled]),
				chatId: chat)
		).records
		let chats = Set((synced + local).compactMap(\.chatId)).subtracting(excluded)
		let conversations = Dictionary(
			uniqueKeysWithValues: chats.map { chat in
				(
					chat,
					ConversationFold.fold(
						chat: chat, synced: synced, local: local, device: deviceId)
				)
			})
		if conversations.values.contains(where: { $0.hasLocalWork(on: deviceId) }) {
			return true
		}
		let jobs = try await flushJobsByChat(in: conversations, local: local)
		return conversations.contains { chat, conversation in
			!FlushJob.outstanding(jobs[chat] ?? [], in: conversation).isEmpty
		}
	}
}

extension Coach {
	func holdsBoundWork() async -> Bool {
		do {
			if try await desk.holdsBoundWork() { return true }
			let opened = mailboxes
			for mailbox in opened.values {
				if try await mailbox.hasLocalWork() { return true }
			}
			return try await ledger.hasLocalWork(excluding: Set(opened.keys))
		} catch {
			switch error {
			case .unavailable, .rejectedBatch: return true
			}
		}
	}
}
