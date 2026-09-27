import Foundation

struct Transcript: Sendable {
	let history: PromptHistory
	let pending: [(ulid: ULID, message: ChatMessage)]
	let unflushed: [(ulid: ULID, message: ChatMessage)]
	let flushPending: Bool
	let current: (ulid: ULID, message: ChatMessage)?
	let lastDate: Date?

	var window: [(ulid: ULID, message: ChatMessage)] {
		pending + unflushed
	}

	func afterReset() -> Transcript {
		Transcript(
			history: PromptHistory(summary: nil, messages: [], ulids: []), pending: window,
			unflushed: [], flushPending: flushPending || !window.isEmpty, current: current,
			lastDate: nil)
	}
}

extension Ledger {

	func loadTranscript(chatId: ChatID, excluding turn: TurnID) async throws -> Transcript {
		let conversation = try await conversation(chatId)
		let jobs = try await flushJobs(in: conversation)
		let lastDate: Date?
		switch conversation.lastExchange {
		case .none: lastDate = nil
		case .at(let date): lastDate = date
		}
		return Transcript(
			history: conversation.current.promptHistory(excluding: turn),
			pending: conversation.outstandingRows(jobs),
			unflushed: conversation.messagesSinceLastFlush(jobs, excluding: turn),
			flushPending: jobs.contains { !$0.settled },
			current: conversation.turn(turn)?.userRow,
			lastDate: lastDate
		)
	}

}
