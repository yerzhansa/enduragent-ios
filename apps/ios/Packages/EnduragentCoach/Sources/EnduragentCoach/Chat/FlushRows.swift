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

	func ulids(for job: FlushJob) -> [ULID] {
		guard job.messages.isEmpty else { return job.messages.filter { byUlid[$0] != nil } }
		let segment = segments.last { $0.id.boundary.map { $0 <= job.id.ulid } ?? true }
		return (segment?.ulids ?? []).filter { $0 < job.id.ulid }
	}

	func messages(for ulids: [ULID]) -> [(ulid: ULID, message: ChatMessage)] {
		ulids.compactMap { ulid in byUlid[ulid].map { (ulid, $0) } }
	}
}

struct FlushRows {
	private let rows: ConversationRows
	let byJob: [FlushJobID: Set<ULID>]

	init(_ jobs: [FlushJob], in conversation: Conversation) {
		let rows = ConversationRows(conversation)
		self.rows = rows
		byJob = Dictionary(
			jobs.map { ($0.id, Set(rows.ulids(for: $0))) }, uniquingKeysWith: { $0.union($1) })
	}

	func outstanding(_ jobs: [FlushJob]) -> [FlushJob] {
		let pending = jobs.filter { !$0.settled }
		return pending.filter { job in !pending.contains { $0.covers(job, resolved: byJob) } }
	}

	func messages(for jobs: [FlushJob]) -> [(ulid: ULID, message: ChatMessage)] {
		let ulids = jobs.reduce(into: Set<ULID>()) { $0.formUnion(byJob[$1.id, default: []]) }
		return rows.messages(for: ulids.sorted())
	}
}
