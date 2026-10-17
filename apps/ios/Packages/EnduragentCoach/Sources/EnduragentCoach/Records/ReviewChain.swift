import Foundation

package protocol ReviewChainLog: RecordLog {
	func newest(_ query: RecordQuery) async throws -> AthleteRecord?
	func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
}

package enum RecordHead: Hashable, Sendable {
	case empty
	case record(ULID)

	package init(_ newest: AthleteRecord?) {
		self = newest.map { .record($0.ulid) } ?? .empty
	}
}

package struct HeadMoved: Error, Sendable, Equatable {
	package let current: RecordHead

	package init(current: RecordHead) {
		self.current = current
	}
}

package enum TransitionFailure: Error, Sendable, Equatable {
	case headMoved(RecordHead)
	case storage(LedgerFailure)
}

extension Ledger {
	private static func chain(of chat: ChatID) -> RecordQuery {
		RecordQuery(scope: .deviceLocal([.workoutReview]), chatId: chat)
	}

	package func reviewHead(chat: ChatID) async throws(LedgerFailure) -> (
		RecordHead, WorkoutReview?
	) {
		try await openIfNeeded()
		let newest: AthleteRecord?
		do {
			newest = try await chain.newest(Self.chain(of: chat))
		} catch {
			throw LedgerFailure.unavailable
		}
		guard let newest else { return (.empty, nil) }
		guard case .deviceLocal(.workoutReview(let body)) = newest.body else {
			throw LedgerFailure.unavailable
		}
		fold(newest.hlc)
		return (.record(newest.ulid), body.review)
	}

	package func commit(review: WorkoutReview, stamp: OperationStamp, after head: RecordHead)
		async throws(TransitionFailure) -> AthleteRecord
	{
		do {
			try await openIfNeeded()
		} catch {
			throw TransitionFailure.storage(error)
		}
		let record = prepare(
			.deviceLocal(.workoutReview(WorkoutReviewBody(review: review))), stamp: stamp)
		do {
			try await chain.append(record, after: head, in: Self.chain(of: review.chat))
		} catch let moved as HeadMoved {
			throw TransitionFailure.headMoved(moved.current)
		} catch {
			throw TransitionFailure.storage(.rejectedBatch)
		}
		return record
	}

	package func markPreparing(
		chat: ChatID, turn: TurnID, attempt: AttemptID, stamp: OperationStamp
	)
		async throws(LedgerFailure)
	{
		_ = try await commit(
			local: [
				.reviewPreparing(ReviewPreparingBody(chatId: chat, turn: turn, attempt: attempt))
			],
			stamp: stamp)
	}

	package func reviewOutcomes(chat: ChatID) async throws(LedgerFailure)
		-> [WorkoutReviewID: ReviewOutcomeBody]
	{
		let page = try await read(RecordQuery(scope: .synced([.reviewOutcome]), chatId: chat))
		var outcomes: [WorkoutReviewID: ReviewOutcomeBody] = [:]
		for record in page.records {
			guard case .synced(.reviewOutcome(let body)) = record.body,
				outcomes[body.review] == nil
			else { continue }
			outcomes[body.review] = body
		}
		return outcomes
	}

	package func reviewPreparing(chat: ChatID, turn: TurnID) async throws(LedgerFailure)
		-> [ReviewPreparingBody]
	{
		try await read(
			RecordQuery(scope: .deviceLocal([.reviewPreparing]), chatId: chat, turn: turn)
		)
		.records.compactMap { record in
			guard case .deviceLocal(.reviewPreparing(let body)) = record.body else { return nil }
			return body
		}
	}
}
