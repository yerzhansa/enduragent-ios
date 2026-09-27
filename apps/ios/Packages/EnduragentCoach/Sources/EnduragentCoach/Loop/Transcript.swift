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
