import Foundation

package protocol ReviewChainLog: RecordLog {
	func newest(_ query: RecordQuery) async throws -> NewestRecord
	func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
	func chats(holding scope: RecordQuery.Scope) async throws -> Set<ChatID>
}

package enum NewestRecord: Sendable, Equatable {
	case empty
	case readable(AthleteRecord)
	case unreadable(SkippedRow)

	package init(_ record: AthleteRecord?) {
		self = record.map(Self.readable) ?? .empty
	}

	package var head: RecordHead {
		switch self {
		case .empty: .empty
		case .readable(let record): .record(record.ulid)
		case .unreadable(let row): .unreadable(row)
		}
	}
}

package enum NewestReview: Sendable {
	case empty
	case readable(ULID, WorkoutReview)
	case unreadable
}

package enum RecordHead: Hashable, Sendable {
	case empty
	case record(ULID)
	case unreadable(SkippedRow)
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
		try await openIfNeeded()
		do {
			return try await chain.chats(holding: .deviceLocal([.workoutReview]))
		} catch {
			throw LedgerFailure.unavailable
		}
	}

	package func commit(review: WorkoutReview, stamp: OperationStamp, after head: RecordHead)
		async throws(TransitionFailure) -> AthleteRecord
	{
		try await commit(
			.deviceLocal(.workoutReview(WorkoutReviewBody(review: review))), stamp: stamp,
			after: head, in: Self.chain(of: review.chat))
	}

	package func head(of query: RecordQuery) async throws(LedgerFailure) -> RecordHead {
		try await newest(query).head
	}

	private func newest(_ query: RecordQuery) async throws(LedgerFailure) -> NewestRecord {
		try await openIfNeeded()
		let newest: NewestRecord
		do {
			newest = try await chain.newest(query)
		} catch {
			throw LedgerFailure.unavailable
		}
		switch newest {
		case .empty: break
		case .readable(let record): fold(record.hlc)
		case .unreadable(let row): report([row])
		}
		return newest
	}

	package func commit(
		synced body: SyncedRecordBody, stamp: OperationStamp, after head: RecordHead,
		in query: RecordQuery
	) async throws(TransitionFailure) {
		_ = try await commit(.synced(body), stamp: stamp, after: head, in: query)
	}

	private func commit(
		_ body: RecordBody, stamp: OperationStamp, after head: RecordHead, in query: RecordQuery
	) async throws(TransitionFailure) -> AthleteRecord {
		do {
			try await openIfNeeded()
		} catch {
			throw TransitionFailure.storage(error)
		}
		let record = prepare(body, stamp: stamp)
		do {
			try await chain.append(record, after: head, in: query)
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
		return Dictionary(
			uniqueKeysWithValues: ReviewOutcomeNotes.notes(from: page.records).map {
				($0.body.review, $0.body)
			})
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
