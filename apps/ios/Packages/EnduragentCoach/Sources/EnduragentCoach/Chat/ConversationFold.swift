import Foundation

package enum ConversationFold {
	package static let syncedScope: RecordQuery.Scope = .synced(
		[.userMessage, .turnSettled, .windowStart],
		includeLegacy: [.userMessage, .assistantMessage, .windowStart]
	)

	package static let localScope: RecordQuery.Scope = .deviceLocal([.turnClaim])

	package static func fold(
		chat: ChatID, synced: [AthleteRecord], local: [AthleteRecord] = [], device: DeviceID
	) -> Conversation {
		let ordered = synced.filter { $0.chatId == chat }.sorted { $0.hlc < $1.hlc }
		let legacyMessages = Set(
			ordered.compactMap { record -> ULID? in
				switch record.body {
				case .legacy(.userMessageV1), .legacy(.assistantMessage): record.ulid
				default: nil
				}
			})
		var boundaries: [(ulid: ULID, opening: SegmentOpening)] = []
		var legacyTrims: [ULID] = []
		for record in ordered {
			switch record.body {
			case .synced(.windowStart(let body)):
				if case .reset(let kind) = body.reason {
					boundaries.append((body.firstIncludedUlid, .reset(kind)))
				}
			case .legacy(.windowStartV1(_, let firstIncluded)):
				if legacyMessages.contains(firstIncluded) {
					legacyTrims.append(firstIncluded)
				} else {
					boundaries.append((firstIncluded, .reset(.daily)))
				}
			default:
				break
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
		var legacyTurns: [(hlc: HybridLogicalClock, device: DeviceID, turn: TurnID)] = []
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
				var facts = TurnFacts(turn: turn, chat: chat, origin: record.deviceId, legacy: true)
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
				legacyTurns.append((record.hlc, record.deviceId, turn))
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
				guard
					let turn = legacyTurns.last(where: {
						$0.device == record.deviceId && $0.hlc < record.hlc
					})?.turn
				else {
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
		for record in local.sorted(by: { $0.hlc < $1.hlc })
		where record.chatId == chat && record.deviceId == device {
			if case .deviceLocal(.turnClaim(let body)) = record.body {
				turns[body.turn]?.claims.append(body)
			}
		}
		for turn in order {
			guard let facts = turns[turn], let first = facts.fragments.first else { continue }
			segments[segmentIndex(for: first.ulid)].turns.append(facts)
		}
		for firstIncluded in legacyTrims {
			segments[segmentIndex(for: firstIncluded)].legacyTrim = firstIncluded
		}
		for record in ordered where record.deviceId == device {
			guard case .synced(.windowStart(let body)) = record.body else { continue }
			switch body.reason {
			case .trim, .compaction:
				segments[segmentIndex(for: record.ulid)].promptWindow = PromptWindow(
					firstIncluded: body.firstIncludedUlid)
			case .reset:
				break
			}
		}
		return Conversation(chat: chat, segments: segments)
	}

	package static func applying(
		_ records: [AthleteRecord], to conversation: Conversation, device: DeviceID
	) -> Conversation {
		var next = conversation
		for record in records {
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
				if let position = next.position(of: body.turn) {
					next.segments[position.segment].turns[position.turn].fragments.append(fragment)
				} else {
					var facts = TurnFacts(turn: body.turn, chat: conversation.chat, origin: device)
					facts.fragments.append(fragment)
					next.appendToCurrent(facts)
				}
			case .synced(.turnSettled(let body)):
				guard let position = next.position(of: body.turn) else { continue }
				next.segments[position.segment].turns[position.turn].settlements.append(
					SettledAttempt(
						ulid: record.ulid,
						hlc: record.hlc,
						civilDate: record.civilDate,
						attempt: body.attempt,
						settlement: body.settlement
					))
			case .deviceLocal(.turnClaim(let body)):
				guard let position = next.position(of: body.turn) else { continue }
				next.segments[position.segment].turns[position.turn].claims.append(body)
			default:
				continue
			}
		}
		return next
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

	package func turn(_ id: TurnID) -> TurnFacts? {
		guard let position = position(of: id) else { return nil }
		return segments[position.segment].turns[position.turn]
	}

	package func turn(withDraft draft: DraftID) -> TurnFacts? {
		for segment in segments {
			for facts in segment.turns where facts.fragments.contains(where: { $0.draft == draft })
			{
				return facts
			}
		}
		return nil
	}

	fileprivate func position(of id: TurnID) -> (segment: Int, turn: Int)? {
		for (segmentIndex, segment) in segments.enumerated() {
			if let turnIndex = segment.turns.firstIndex(where: { $0.turn == id }) {
				return (segmentIndex, turnIndex)
			}
		}
		return nil
	}

	package mutating func settle(_ turn: TurnID, with settled: SettledAttempt) {
		guard let position = position(of: turn) else { return }
		segments[position.segment].turns[position.turn].settlements.append(settled)
	}

	fileprivate mutating func appendToCurrent(_ facts: TurnFacts) {
		if segments.isEmpty {
			segments.append(Segment(id: SegmentID(boundary: nil), openedBy: .chatStart))
		}
		segments[segments.count - 1].turns.append(facts)
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
	package var legacyTrim: ULID?

	package var messages: [ChatMessage] {
		turns.flatMap { visibleRows(of: $0).map(\.message) }
	}

	package func promptHistory(excluding turn: TurnID?) -> PromptHistory {
		var history = PromptHistory(messages: [], ulids: [])
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

package struct TurnFacts: Sendable, Equatable {
	package let turn: TurnID
	package let chat: ChatID
	package let origin: DeviceID
	package var legacy = false
	package var fragments: [Fragment] = []
	package var claims: [TurnClaimBody] = []
	package var settlements: [SettledAttempt] = []

	package var requestText: String {
		fragments.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
	}

	package var slash: SlashCommand? {
		fragments.min { $0.index < $1.index }?.slash
	}

	package var latestSettlement: SettledAttempt? {
		settlements.max { $0.hlc < $1.hlc }
	}

	package var openClaims: [TurnClaimBody] {
		claims.filter { claim in !settlements.contains { $0.attempt == claim.attempt } }
	}

	var lastUlid: ULID {
		(fragments.map(\.ulid) + settlements.map(\.ulid)).max() ?? turn.ulid
	}

	var messageRows: [(ulid: ULID, message: ChatMessage)] {
		guard let first = fragments.min(by: { $0.index < $1.index }) else { return [] }
		let question = (
			first.ulid, ChatMessage(role: .user, text: requestText, civilDate: first.civilDate)
		)
		guard let settled = latestSettlement else {
			return legacy ? [question] : []
		}
		let replyText: String
		switch settled.settlement {
		case .replied(.model(let text), _):
			replyText = text
		case .interrupted(let partial, _, _) where !partial.isEmpty:
			replyText = partial
		case .interrupted, .failed:
			return []
		}
		return [
			question,
			(
				settled.ulid,
				ChatMessage(role: .assistant, text: replyText, civilDate: settled.civilDate)
			),
		]
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
