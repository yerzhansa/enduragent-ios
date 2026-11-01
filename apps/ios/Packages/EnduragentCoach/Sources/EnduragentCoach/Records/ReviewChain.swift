import Foundation

package protocol ReviewChainLog: RecordLog {
	func newest(_ query: RecordQuery) async throws -> NewestRecord
	func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
	func chats(holding scope: RecordQuery.Scope) async throws -> Set<ChatID>
}

package enum NewestReview: Sendable {
	case empty
	case readable(ULID, WorkoutReview)
	case unreadable
}

extension Ledger {
	private static func chain(of chat: ChatID) -> RecordQuery {
		RecordQuery(scope: .deviceLocal([.workoutReview]), chatId: chat)
	}

	package func reviewHead(chat: ChatID) async throws(LedgerFailure) -> (
		RecordHead, WorkoutReview?
	) {
		switch try await newestReview(chat: chat) {
		case .empty: (.empty, nil)
		case .unreadable: throw LedgerFailure.unavailable
		case .readable(let head, let review): (.record(head), review)
		}
	}

	package func newestReview(chat: ChatID) async throws(LedgerFailure) -> NewestReview {
		switch try await newest(Self.chain(of: chat)) {
		case .empty:
			return .empty
		case .unreadable:
			return .unreadable
		case .readable(let record):
			guard case .deviceLocal(.workoutReview(let body)) = record.body else {
				throw LedgerFailure.unavailable
			}
			return .readable(record.ulid, body.review)
		}
	}

	package func reviewChats() async throws(LedgerFailure) -> Set<ChatID> {
		try await chats(holding: .workoutReview)
	}

	package func commit(review: WorkoutReview, stamp: OperationStamp, after head: RecordHead)
		async throws(TransitionFailure) -> AthleteRecord
	{
		try await append(
			.deviceLocal(.workoutReview(WorkoutReviewBody(review: review))), stamp: stamp,
			after: head, in: Self.chain(of: review.chat))
	}

	package func commit(
		synced body: SyncedRecordBody, stamp: OperationStamp, after head: RecordHead,
		in query: RecordQuery
	) async throws(TransitionFailure) {
		_ = try await append(.synced(body), stamp: stamp, after: head, in: query)
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
		return Dictionary(
			uniqueKeysWithValues: ReviewOutcomeNotes.notes(from: page.records).map {
				($0.body.review, $0.body)
			})
	}

	package func newestReviewOutcome(
		chat: ChatID, visibleIn scope: InformationReadScope, using ownership: InformationOwnership
	) async throws(LedgerFailure) -> ReviewOutcomeBody? {
		let page = try await read(RecordQuery(scope: .synced([.reviewOutcome]), chatId: chat))
		return ReviewOutcomeNotes.notes(from: page.records).last {
			scope.contains(ownership.rowOwner(account: $0.record.account))
		}?.body
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
