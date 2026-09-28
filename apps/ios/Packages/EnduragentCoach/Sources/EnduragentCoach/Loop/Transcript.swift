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
}

extension Ledger {
	func loadTranscript(chatId: ChatID, excluding turn: TurnID) async throws -> Transcript {
		let conversation = try await conversation(chatId)
		let jobs = try await flushJobs(in: conversation)
		return Transcript(
			history: conversation.current.promptHistory(excluding: turn),
			pending: conversation.outstandingRows(jobs),
			unflushed: conversation.messagesSinceLastFlush(jobs, excluding: turn),
			flushPending: jobs.contains { !$0.settled },
			current: conversation.turn(turn)?.userRow
		)
	}
}
