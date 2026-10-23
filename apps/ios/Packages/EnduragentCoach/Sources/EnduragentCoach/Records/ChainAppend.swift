import Foundation

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
	func chats(holding kind: DeviceLocalKind) async throws(LedgerFailure) -> Set<ChatID> {
		try await openIfNeeded()
		do {
			return try await chain.chats(holding: .deviceLocal([kind]))
		} catch {
			throw LedgerFailure.unavailable
		}
	}

	package func head(of query: RecordQuery) async throws(LedgerFailure) -> RecordHead {
		try await newest(query).head
	}

	func newest(_ query: RecordQuery) async throws(LedgerFailure) -> NewestRecord {
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

	func append(
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
}
