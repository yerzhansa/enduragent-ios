import Foundation

package protocol WorkoutReviews: Sendable {
	func isExecuting(in chat: ChatID) async -> Bool
	func snapshot(chat: ChatID) async throws(LedgerFailure) -> ReviewSnapshot?
}

extension ReviewDecision {
	package var ref: ReviewRef {
		switch self {
		case .presented(let ref), .presentationFailed(let ref), .showAgain(let ref),
			.checkAgain(let ref):
			ref
		case .approve(let token), .retryRemaining(let token), .cancel(let token):
			token.ref
		}
	}
}
