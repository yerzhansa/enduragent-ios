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
