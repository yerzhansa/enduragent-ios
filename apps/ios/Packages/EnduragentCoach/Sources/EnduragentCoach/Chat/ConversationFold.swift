import Foundation

package enum ConversationFold {
	package static let syncedScope: RecordQuery.Scope = .synced(
		[.userMessage, .turnSettled, .windowStart],
		includeLegacy: [.userMessage, .assistantMessage, .windowStart]
	)

	package static func fold(chat: ChatID, synced: [AthleteRecord], device: DeviceID)
		-> Conversation
	{
		let ordered = synced.filter { $0.chatId == chat }.sorted { $0.hlc < $1.hlc }
		var boundaries: [(ulid: ULID, opening: SegmentOpening)] = []
		for record in ordered {
			if case .synced(.windowStart(let body)) = record.body,
				case .reset(let kind) = body.reason
			{
				boundaries.append((body.firstIncludedUlid, .reset(kind)))
			}
		}
		boundaries.sort { $0.ulid < $1.ulid }
		var segments = [Segment(id: SegmentID(boundary: nil), openedBy: .chatStart)]
		for boundary in boundaries {
			segments.append(
				Segment(id: SegmentID(boundary: boundary.ulid), openedBy: boundary.opening))
		}
		func segmentIndex(for ulid: ULID) -> Int {
			var index = 0
			for (position, boundary) in boundaries.enumerated() where boundary.ulid <= ulid {
				index = position + 1
			}
			return index
		}

		var turns: [TurnID: TurnFacts] = [:]
		var order: [TurnID] = []
		var legacyTurns: [(hlc: HybridLogicalClock, turn: TurnID)] = []
		for record in ordered {
			switch record.body {
			case .synced(.userMessage(let body)):
				let fragment = Fragment(
					ulid: record.ulid,
					hlc: record.hlc,
					civilDate: record.civilDate,
					index: body.fragment,
					draft: body.draft,
					text: body.athleteText,
					slash: body.slash
				)
				if turns[body.turn] == nil {
					turns[body.turn] = TurnFacts(
						turn: body.turn, chat: chat, origin: record.deviceId)
					order.append(body.turn)
				}
				turns[body.turn]?.fragments.append(fragment)
			case .legacy(.userMessageV1(_, let text, let slash)):
				let turn = TurnID(ulid: record.ulid)
				var facts = TurnFacts(turn: turn, chat: chat, origin: record.deviceId)
				facts.fragments.append(
					Fragment(
						ulid: record.ulid,
						hlc: record.hlc,
						civilDate: record.civilDate,
						index: 0,
						draft: nil,
						text: text,
						slash: slash
					)
				)
				turns[turn] = facts
				order.append(turn)
				legacyTurns.append((record.hlc, turn))
			default:
				break
			}
		}
		for record in ordered {
			switch record.body {
			case .synced(.turnSettled(let body)):
				turns[body.turn]?.settlements.append(
					SettledAttempt(
						ulid: record.ulid,
						hlc: record.hlc,
						civilDate: record.civilDate,
						attempt: body.attempt,
						settlement: body.settlement
					)
				)
			case .legacy(.assistantMessage(let body)):
				guard let turn = legacyTurns.last(where: { $0.hlc < record.hlc })?.turn else {
					continue
				}
				turns[turn]?.settlements.append(
					SettledAttempt(
						ulid: record.ulid,
						hlc: record.hlc,
						civilDate: record.civilDate,
						attempt: AttemptID(ulid: record.ulid),
						settlement: .replied(
							.model(body.text),
							lineage: ReplyLineage(
								templateHash: body.templateHash, assembledHash: body.assembledHash)
						)
					)
				)
			default:
				break
			}
		}
		for turn in order {
			guard let facts = turns[turn], let first = facts.fragments.first else { continue }
			segments[segmentIndex(for: first.ulid)].turns.append(facts)
		}
		for record in ordered where record.deviceId == device {
			let window: (ulid: ULID, firstIncluded: ULID)?
			switch record.body {
			case .synced(.windowStart(let body)):
				switch body.reason {
				case .trim, .compaction:
					window = (record.ulid, body.firstIncludedUlid)
				case .reset:
					window = nil
				}
			case .legacy(.windowStartV1(_, let firstIncluded)):
				window = (record.ulid, firstIncluded)
			default:
				window = nil
			}
			if let window {
				segments[segmentIndex(for: window.ulid)].promptWindow = PromptWindow(
					firstIncluded: window.firstIncluded)
			}
		}
		return Conversation(chat: chat, segments: segments)
	}
}

package struct Conversation: Sendable, Equatable {
	package let chat: ChatID
	package var segments: [Segment]

	package var current: Segment {
		guard let last = segments.last else {
			return Segment(id: SegmentID(boundary: nil), openedBy: .chatStart)
		}
		return last
	}

	package var lastExchange: LastExchange {
		let stamps = current.turns.flatMap { turn in
			turn.fragments.map(\.hlc) + turn.settlements.map(\.hlc)
		}
		guard let latest = stamps.max() else { return .none }
		return .at(Date(timeIntervalSince1970: Double(latest.wallMs) / 1000))
	}

	package func messages(for ulids: [ULID]) -> [ChatMessage] {
		var byUlid: [ULID: ChatMessage] = [:]
		for segment in segments {
			for turn in segment.turns {
				for (ulid, message) in turn.messageRows {
					byUlid[ulid] = message
				}
			}
		}
		return ulids.compactMap { byUlid[$0] }
	}
}

package enum LastExchange: Sendable, Equatable {
	case none
	case at(Date)
}

package struct SegmentID: Hashable, Sendable {
	package let boundary: ULID?
}

package enum SegmentOpening: Sendable, Equatable {
	case chatStart
	case reset(ResetKind)
}

package struct PromptWindow: Sendable, Equatable {
	package var firstIncluded: ULID?
}

package struct PromptHistory: Sendable, Equatable {
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
	package var promptWindow = PromptWindow(firstIncluded: nil)

	package var messages: [ChatMessage] {
		turns.flatMap { $0.messageRows.map(\.message) }
	}

	package func promptHistory(excluding turn: TurnID?) -> PromptHistory {
		var history = PromptHistory(messages: [], ulids: [])
		for facts in turns where facts.turn != turn {
			if let firstIncluded = promptWindow.firstIncluded, facts.lastUlid < firstIncluded {
				continue
			}
			for (ulid, message) in facts.messageRows {
				history.messages.append(message)
				history.ulids.append(ulid)
			}
		}
		return history
	}
}

package struct TurnFacts: Sendable, Equatable {
	package let turn: TurnID
	package let chat: ChatID
	package let origin: DeviceID
	package var fragments: [Fragment] = []
	package var settlements: [SettledAttempt] = []

	package var requestText: String {
		fragments.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
	}

	package var latestSettlement: SettledAttempt? {
		settlements.max { $0.hlc < $1.hlc }
	}

	var lastUlid: ULID {
		(fragments.map(\.ulid) + settlements.map(\.ulid)).max() ?? turn.ulid
	}

	var messageRows: [(ulid: ULID, message: ChatMessage)] {
		guard let first = fragments.min(by: { $0.index < $1.index }) else { return [] }
		var rows = [
			(first.ulid, ChatMessage(role: .user, text: requestText, civilDate: first.civilDate))
		]
		if let settled = latestSettlement, case .replied(.model(let text), _) = settled.settlement {
			rows.append(
				(
					settled.ulid,
					ChatMessage(role: .assistant, text: text, civilDate: settled.civilDate)
				)
			)
		}
		return rows
	}
}

package struct Fragment: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let civilDate: CivilDate
	package let index: Int
	package let draft: DraftID?
	package let text: String
	package let slash: SlashCommand?
}

package struct SettledAttempt: Sendable, Equatable {
	package let ulid: ULID
	package let hlc: HybridLogicalClock
	package let civilDate: CivilDate
	package let attempt: AttemptID
	package let settlement: Settlement
}
