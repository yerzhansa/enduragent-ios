import Foundation

extension ChatMailbox {
	func snapshot() -> ChatSnapshot {
		ChatSnapshot(
			chat: chatId,
			conversation: records.conversation,
			jobs: records.jobs,
			live: live,
			window: work.window,
			queued: work.turns(includingActive: true),
			waiting: waits.waiting(among: records.conversation.current.turns),
			stopping: interruption.cause != nil,
			resetting: work.resetting,
			finishedAway: finishedAway,
			review: records.review,
			device: ledger.deviceId,
			process: process,
			now: clock.now,
			zone: clock.timeZone
		)
	}
}
