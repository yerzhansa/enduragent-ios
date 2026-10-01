struct ConversationRows {
	@TaskLocal static var didResolveRow: (@Sendable () -> Void)?
	private let byUlid: [ULID: ChatMessage]
	private let segments: [(id: SegmentID, ulids: [ULID])]

	init(_ conversation: Conversation) {
		var byUlid: [ULID: ChatMessage] = [:]
		var segments: [(id: SegmentID, ulids: [ULID])] = []
		for segment in conversation.segments {
			var ulids: [ULID] = []
			for turn in segment.turns {
				let messages = turn.messageRows
				let indexed =
					messages.isEmpty ? [turn.userRow, turn.replyRow].compactMap({ $0 }) : messages
				for (ulid, message) in indexed {
					Self.didResolveRow?()
					byUlid[ulid] = message
				}
				ulids.append(contentsOf: messages.map(\.ulid))
			}
			segments.append((segment.id, ulids))
		}
		self.byUlid = byUlid
		self.segments = segments
	}

	func coverage(
		for id: FlushJobID, messages: [ULID], origin: FlushJob.Origin, consumed: Bool = false
	) -> FlushJob.Coverage {
		let legacy: FlushJob.Coverage.Legacy? =
			if origin != .beforeUpgrade {
				nil
			} else if messages.isEmpty {
				.before(id.ulid)
			} else if consumed, let through = messages.max() {
				.through(through)
			} else {
				nil
			}
		return FlushJob.Coverage(
			listed: messages, resolved: Set(ulids(for: id, messages: messages)), legacy: legacy)
	}

	func resolving(_ job: FlushJob) -> FlushJob {
		FlushJob(
			id: job.id, origin: job.origin,
			coverage: .init(
				listed: job.coverage.listed,
				resolved: Set(ulids(for: job.id, messages: job.coverage.listed)),
				legacy: job.coverage.legacy), phase: job.phase, reset: job.reset)
	}

	func outstanding(_ jobs: [FlushJob]) -> [FlushJob] {
		let pending = jobs.filter { $0.phase == .pending }.map(resolving)
		return pending.filter { job in !pending.contains { $0.covers(job) } }
	}

	func ulids(for id: FlushJobID, messages: [ULID]) -> [ULID] {
		guard messages.isEmpty else { return messages.filter { byUlid[$0] != nil } }
		let segment = segments.last { $0.id.boundary.map { $0 <= id.ulid } ?? true }
		return (segment?.ulids ?? []).filter { $0 < id.ulid }
	}

	func messages(for ulids: [ULID]) -> [(ulid: ULID, message: ChatMessage)] {
		ulids.compactMap { ulid in byUlid[ulid].map { (ulid, $0) } }
	}
}
