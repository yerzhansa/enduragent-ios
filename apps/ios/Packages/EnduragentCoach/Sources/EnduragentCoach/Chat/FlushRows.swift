struct ConversationRows {
	@TaskLocal static var didResolveRow: (@Sendable () -> Void)?
	private let byUlid: [ULID: ConversationRow]
	private let ownership: InformationOwnership
	private let segments: [(id: SegmentID, ulids: [ULID])]

	init(_ conversation: Conversation) {
		var byUlid: [ULID: ConversationRow] = [:]
		var segments: [(id: SegmentID, ulids: [ULID])] = []
		for segment in conversation.segments {
			var ulids: [ULID] = []
			for turn in segment.turns {
				let messages = turn.messageRows(using: conversation.ownership)
				let indexed =
					messages.isEmpty ? [turn.userRow, turn.replyRow].compactMap({ $0 }) : messages
				for row in indexed {
					Self.didResolveRow?()
					byUlid[row.ulid] = row
				}
				ulids.append(contentsOf: messages.map(\.ulid))
			}
			segments.append((segment.id, ulids))
		}
		self.ownership = conversation.ownership
		self.byUlid = byUlid
		self.segments = segments
	}

	func source(for record: AthleteRecord, body: FlushPendingBody, coverage: FlushJob.Coverage)
		-> FlushSource
	{
		if body.sourceBound {
			return .bound(
				ownership.sourceBinding(
					for: record.account, jobDevice: record.deviceId, zone: record.timeZone))
		}
		let sources = OwnedFlushRows.partition(
			messages(for: coverage.resolved.sorted()), using: ownership, jobDevice: record.deviceId,
			zone: record.timeZone)
		return sources.count == 1 ? .bound(sources[0].binding) : .recoverFromRows
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
				legacy: job.coverage.legacy), source: job.source, parent: job.parent,
			phase: job.phase, reset: job.reset)
	}

	func outstanding(_ jobs: [FlushJob]) -> [FlushJob] {
		let pending = jobs.filter { job in
			job.phase == .pending && !jobs.contains { $0.id == job.parent && $0.phase == .pending }
		}.map(resolving)
		return pending.filter { job in !pending.contains { $0.covers(job) } }
	}

	func ulids(for id: FlushJobID, messages: [ULID]) -> [ULID] {
		guard messages.isEmpty else { return messages.filter { byUlid[$0] != nil } }
		let segment = segments.last { $0.id.boundary.map { $0 <= id.ulid } ?? true }
		return (segment?.ulids ?? []).filter { $0 < id.ulid }
	}

	func messages(for ulids: [ULID]) -> [ConversationRow] {
		ulids.compactMap { byUlid[$0] }
	}
}
