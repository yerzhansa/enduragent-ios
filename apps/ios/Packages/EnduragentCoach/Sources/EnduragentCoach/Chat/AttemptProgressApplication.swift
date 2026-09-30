extension ChatRecords {
	func apply(
		_ progress: AttemptProgress, turn: TurnID, stamp: OperationStamp,
		isolation: isolated (any Actor)? = #isolation
	) async {
		if case .textDelta(let delta) = progress, !delta.isEmpty {
			await observeReply(turn, stamp: stamp)
		}
		if case .proposalPending = progress {
			await refreshReview()
		}
	}
}

extension MailboxQueue {
	func apply(_ progress: AttemptProgress, attempt: AttemptID) {
		guard var current = phase.running?.attempt, current.live.attempt == attempt else {
			return
		}
		current.live.apply(progress)
		show(current)
	}
}
