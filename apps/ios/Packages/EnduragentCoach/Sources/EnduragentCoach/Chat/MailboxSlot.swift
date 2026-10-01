import Foundation

struct MailboxSlot: Sendable {
	let feed = SnapshotFeed()
	var opening: Task<Result<ChatMailbox, LedgerFailure>, Never>?
	var mailbox: ChatMailbox?
}
