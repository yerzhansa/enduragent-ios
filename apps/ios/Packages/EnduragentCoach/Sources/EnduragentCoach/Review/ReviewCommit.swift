import Foundation

package enum ReviewNotPrepared: String, Equatable, Sendable {
	case incomplete
	case refused
	case notSaved
	case turnDidNotFinish
	case processEnded
}

package enum PreparationOutcome: Equatable, Sendable {
	case none
	case committed(ReviewBase)
	case notPrepared(ReviewNotPrepared)

	package var notPrepared: ReviewNotPrepared? {
		guard case .notPrepared(let cause) = self else { return nil }
		return cause
	}
}

extension ReviewDraft {
	func committed(
		over base: WorkoutReview?, id fresh: WorkoutReviewID,
		minting mint: @Sendable () async -> ChangeID
	) async -> WorkoutReview? {
		guard case .changes(let targets, let kept) = content else { return nil }
		let carried = Dictionary(
			(base?.work.remaining ?? []).map { ($0.id, $0.position) },
			uniquingKeysWith: { first, _ in first })
		let taken =
			(base?.work.finished.map(\.change.position) ?? [])
			+ targets.compactMap { $0.reuse.flatMap { carried[$0] } }
		var next = (taken.max() ?? -1) + 1
		var work: [ReviewChange] = []
		for target in targets {
			if let reused = target.reuse, let position = carried[reused] {
				work.append(ReviewChange(id: reused, position: position, action: target.action))
			} else {
				work.append(ReviewChange(id: await mint(), position: next, action: target.action))
				next += 1
			}
		}
		return WorkoutReview.committing(self, work, kept: kept, over: base, id: fresh)
	}
}
