import Foundation

extension ChatMailbox {
	static func open(
		chatId: ChatID, ledger: Ledger, runner: TurnRunner, flushes: FlushWork,
		clock: any Clock, coalescing: CoalescingPolicy,
		coalescingSleep: @escaping @Sendable (Duration) async throws -> Void = SystemClock().sleep,
		environment: EnvironmentResolver, reviews: any WorkoutReviews, process: ProcessID,
		host: any ExecutionHost, lifetime: Coach.Lifetime, feed: SnapshotFeed<ChatSnapshot>,
		recoveryRecords: [AthleteRecord]? = nil
	) async throws(LedgerFailure) -> ChatMailbox {
		try await ChatMailbox(
			chatId: chatId, ledger: ledger, runner: runner, flushes: flushes,
			clock: clock, coalescing: coalescing, coalescingSleep: coalescingSleep,
			environment: environment, reviews: reviews, process: process, host: host,
			lifetime: lifetime, feed: feed, recoveryRecords: recoveryRecords)
	}

}
