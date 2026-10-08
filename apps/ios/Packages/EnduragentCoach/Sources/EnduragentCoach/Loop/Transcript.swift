import Foundation

struct Transcript: Sendable {
	let history: PromptHistory
	let pending: [ConversationRow]
	let unflushed: [ConversationRow]
	let flushPending: Bool
	let current: ConversationRow?

	var window: [ConversationRow] { pending + unflushed }

	init(
		conversation: Conversation, jobs: [FlushJob], excluding turn: TurnID,
		for account: TrainingAccount, device: DeviceID, using ownership: InformationOwnership
	) {
		let scope = ownership.scope(for: account, device: device)
		history = conversation.current.promptHistory(
			excluding: turn, for: account, device: device, using: ownership)
		pending = conversation.outstandingRows(jobs).filter { scope.contains($0, using: ownership) }
		unflushed = conversation.messagesSinceLastFlush(jobs, excluding: turn).filter {
			scope.contains($0, using: ownership)
		}
		flushPending = !pending.isEmpty
		current = conversation.turn(turn).flatMap {
			$0.questionRow(for: $0.latestAttempt, using: ownership)
		}.flatMap {
			scope.contains($0, using: ownership) ? $0 : nil
		}
	}
}
