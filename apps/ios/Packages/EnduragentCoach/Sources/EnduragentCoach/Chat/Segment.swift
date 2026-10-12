import Foundation

package struct SegmentID: Hashable, Sendable {
	package let boundary: ULID?
}

package enum SegmentOpening: Sendable, Equatable {
	case chatStart
	case reset(ResetID)
	case legacyBoundary
}

package struct ReviewNote: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let date: CivilDate
	package let account: TrainingAccount
	package let content: TranscriptNote.Content
	package var after: TurnID? = nil
}

package struct PromptWindow: Sendable, Equatable {
	package struct Trim: Sendable, Equatable {
		package let messageUlids: Set<ULID>
		package let opened: ULID
	}

	package var trim: Trim?
	package var summary: CompactionSummaryBody?

	mutating func summarize(_ body: CompactionSummaryBody, at ulid: ULID) {
		if let opened = trim?.opened, ulid < opened {
			return
		}
		summary = body
	}
}

package struct ConversationRow: Sendable, Equatable {
	package let ulid: ULID
	package let origin: DeviceID
	package let account: TrainingAccount
	package let message: ChatMessage
}

package struct PromptHistory: Sendable, Equatable {
	package var summary: String?
	package var rows: [ConversationRow]

	package var messages: [ChatMessage] { rows.map(\.message) }
	package var ulids: [ULID] { rows.map(\.ulid) }
}

package struct Segment: Sendable, Equatable {
	package let id: SegmentID
	package let openedBy: SegmentOpening
	package var boundary: SegmentBoundary? = nil
	package var turns: [TurnFacts] = []
	package var notes: [ReviewNote] = []
	package var promptWindows: [InformationOwner: PromptWindow] = [:]
	package var legacyTrim: ULID?

	package var messages: [ChatMessage] {
		turns.flatMap { facts -> [ChatMessage] in
			guard facts.replyRow != nil || (facts.legacy && facts.latestSettlement == nil) else {
				return []
			}
			return [facts.userRow, facts.replyRow].compactMap { $0 }.filter { !isTrimmed($0.ulid) }
				.map(
					\.message)
		}
	}

	package func hidesQuestion(of facts: TurnFacts) -> Bool {
		facts.userRow.map { isTrimmed($0.ulid) } ?? false
	}

	package func hidesWholly(_ facts: TurnFacts) -> Bool {
		hidesQuestion(of: facts) && (facts.latestSettlement.map { isTrimmed($0.ulid) } ?? true)
	}

	func visibleRows(of facts: TurnFacts, using ownership: InformationOwnership)
		-> [ConversationRow]
	{
		facts.messageRows(using: ownership).filter { !isTrimmed($0.ulid) }
	}

	private func isTrimmed(_ ulid: ULID) -> Bool {
		guard let legacyTrim else { return false }
		return ulid < legacyTrim
	}
}
