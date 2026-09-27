import Foundation

extension Ledger {
	package func conversation(_ chat: ChatID) async throws(LedgerFailure) -> Conversation {
		let synced = try await read(RecordQuery(scope: ConversationFold.syncedScope, chatId: chat))
		let local = try await read(RecordQuery(scope: ConversationFold.localScope, chatId: chat))
		return ConversationFold.fold(
			chat: chat, synced: synced.records, local: local.records, device: deviceId)
	}
}
