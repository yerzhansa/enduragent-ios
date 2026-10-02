import Foundation

struct MailboxSnapshotInput {
	let conversation: Conversation
	let jobs: [FlushJob]
	let phase: MailboxPhase
	let window: OpenWindow?
	let queued: [MailboxWork]
	let finishedAway: Set<TurnID>
	let unsavedTurns: Set<TurnID>
	let review: ReviewSnapshot?
	let reset: ResetStatus
	let resetMemory: MemorySaveResult?
}

final class MailboxSnapshots {
	private let chat: ChatID
	private let device: DeviceID
	private let process: ProcessID
	private let clock: any Clock
	private let feed: SnapshotFeed<ChatSnapshot>
	private let waits: RetryWaits
	private var projection = TurnProjection()
	private var latest: ChatSnapshot?
	private var revision: UInt64 = 0

	init(
		chat: ChatID, device: DeviceID, process: ProcessID, clock: any Clock,
		feed: SnapshotFeed<ChatSnapshot>, wake: @escaping RetryWaits.Wake
	) {
		self.chat = chat
		self.device = device
		self.process = process
		self.clock = clock
		self.feed = feed
		self.waits = RetryWaits(clock: clock, wake: wake)
	}

	func waiting(among turns: [TurnFacts]) -> Set<TurnID> {
		waits.waiting(among: turns)
	}

	func waitEnded(_ turn: TurnID, _ attempt: AttemptID) -> Bool {
		waits.end(turn, attempt: attempt)
	}

	func observe(_ input: MailboxSnapshotInput) -> AsyncStream<ChatSnapshot> {
		let current = snapshot(input)
		latest = current
		return feed.subscribe(from: current)
	}

	func publish(
		_ input: @autoclosure () -> MailboxSnapshotInput, liveText: Bool, live: LiveAttempt?
	) {
		let current: ChatSnapshot
		if liveText, var cached = latest {
			cached.liveReply = LiveReply(live)
			revision += 1
			cached.revision = revision
			current = cached
		} else {
			current = snapshot(input())
		}
		latest = current
		feed.publish(current)
	}

	private func snapshot(_ input: MailboxSnapshotInput) -> ChatSnapshot {
		revision += 1
		return ChatSnapshot(
			chat: chat, revision: revision, projection: &projection,
			conversation: input.conversation, jobs: input.jobs, phase: input.phase,
			window: input.window, queued: input.queued,
			waiting: waits.waiting(among: input.conversation.current.turns),
			finishedAway: input.finishedAway, unsavedTurns: input.unsavedTurns,
			review: input.review, reset: input.reset, resetMemory: input.resetMemory,
			device: device, process: process, now: clock.now, zone: clock.timeZone)
	}
}
