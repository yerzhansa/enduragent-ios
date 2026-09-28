import Foundation

package struct SegmentID: Hashable, Sendable {
	package let boundary: ULID?
}

package enum SegmentOpening: Sendable, Equatable {
	case chatStart
	case reset(ResetKind)
}

package struct ReviewNote: Sendable, Equatable {
	package let ulid: ULID
	package let summary: String
}

package struct PromptWindow: Sendable, Equatable {
	package var firstIncluded: ULID?
	package var opened: ULID?
	package var summary: CompactionSummaryBody?

	mutating func summarize(_ body: CompactionSummaryBody, at ulid: ULID) {
		if let opened, ulid < opened {
			return
		}
		summary = body
	}
}

package struct PromptHistory: Sendable, Equatable {
	package var summary: String?
	package var messages: [ChatMessage]
	package var ulids: [ULID]

	package func ulid(for message: ChatMessage) -> ULID? {
		guard let index = messages.firstIndex(of: message) else { return nil }
		return ulids[index]
	}
}

package struct Segment: Sendable, Equatable {
	package let id: SegmentID
	package let openedBy: SegmentOpening
	package var turns: [TurnFacts] = []
	package var notes: [ReviewNote] = []
	package var promptWindow = PromptWindow()
	package var legacyTrim: ULID?

	package var messages: [ChatMessage] {
		turns.flatMap { visibleRows(of: $0).map(\.message) }
	}

	package func promptHistory(excluding turn: TurnID?) -> PromptHistory {
		var history = PromptHistory(
			summary: promptWindow.summary?.markdown, messages: [], ulids: [])
		for facts in turns where facts.turn != turn {
			if let firstIncluded = promptWindow.firstIncluded, facts.lastUlid < firstIncluded {
				continue
			}
			for (ulid, message) in visibleRows(of: facts) {
				history.messages.append(message)
				history.ulids.append(ulid)
			}
		}
		return history
	}

	package func hidesQuestion(of facts: TurnFacts) -> Bool {
		facts.fragments.min { $0.index < $1.index }.map { isTrimmed($0.ulid) } ?? false
	}

	package func hidesWholly(_ facts: TurnFacts) -> Bool {
		hidesQuestion(of: facts) && (facts.latestSettlement.map { isTrimmed($0.ulid) } ?? true)
	}

	private func visibleRows(of facts: TurnFacts) -> [(ulid: ULID, message: ChatMessage)] {
		facts.messageRows.filter { !isTrimmed($0.ulid) }
	}

	private func isTrimmed(_ ulid: ULID) -> Bool {
		guard let legacyTrim else { return false }
		return ulid < legacyTrim
	}
}
