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
		in chat: ChatID? = nil, excluding excluded: Set<ChatID> = [], now: Date
	) async throws(LedgerFailure) -> Bool {
		let synced = try await read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chat)
		).records
		let local = try await read(
			RecordQuery(
				scope: .deviceLocal([
					.turnClaim, .replyObserved, .flushPending, .flushSettled,
					.pendingProposal, .proposalCleared,
				]), chatId: chat)
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
		for (chat, conversation) in conversations {
			if try await calendarWrites(chat).contains(where: {
				$0.body.evidence.dispatched && !$0.body.evidence.applied
			}) {
				return true
			}
			if conversation.hasLocalWork(on: deviceId)
				|| UnionMerge.pendingProposalRecord(local, chatId: chat, now: now) != nil
			{
				return true
			}
		}
		let jobs = try await flushJobsByChat(in: conversations, local: local)
		return conversations.contains { chat, conversation in
			!FlushJob.outstanding(jobs[chat] ?? [], in: conversation).isEmpty
		}
	}
}

extension Coach {
	func holdsBoundWork(now: Date) async -> Bool {
		do {
			let opened = mailboxes
			for mailbox in opened.values {
				if try await mailbox.hasLocalWork() { return true }
			}
			return try await ledger.hasLocalWork(excluding: Set(opened.keys), now: now)
		} catch {
			switch error {
			case .unavailable, .rejectedBatch: return true
			}
		}
	}
}
