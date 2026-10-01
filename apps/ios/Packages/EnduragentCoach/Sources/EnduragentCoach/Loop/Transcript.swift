import Foundation

struct Transcript: Sendable {
	let history: PromptHistory
	let pending: [(ulid: ULID, message: ChatMessage)]
	let unflushed: [(ulid: ULID, message: ChatMessage)]
	let flushPending: Bool
	let current: (ulid: ULID, message: ChatMessage)?

	var window: [(ulid: ULID, message: ChatMessage)] {
		pending + unflushed
	}

	init(conversation: Conversation, jobs: [FlushJob], excluding turn: TurnID) {
		history = conversation.current.promptHistory(excluding: turn)
		pending = conversation.outstandingRows(jobs)
		unflushed = conversation.messagesSinceLastFlush(jobs, excluding: turn)
		flushPending = jobs.contains { $0.phase == .pending }
		current = conversation.turn(turn)?.userRow
	}
}
