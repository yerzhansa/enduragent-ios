import Foundation

package enum ConversationFold {
	package static let syncedScope: RecordQuery.Scope = .synced(
		[.userMessage, .turnSettled, .windowStart, .compactionSummary, .reviewApplied],
		includeLegacy: [.userMessage, .assistantMessage, .windowStart]
	)

	package static let localScope: RecordQuery.Scope = .deviceLocal([.turnClaim, .replyObserved])

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
			switch record.body {
			case .deviceLocal(.turnClaim(let body)):
				turns[body.turn]?.claims.append(ClaimedAttempt(hlc: record.hlc, body: body))
			case .deviceLocal(.replyObserved(let body)):
				turns[body.turn]?.replyObserved.append(body)
			default:
				break
			}
		}
		for turn in order {
			guard let facts = turns[turn], let first = facts.fragments.first else { continue }
			segments[segmentIndex(for: first.ulid)].turns.append(facts)
		}
		for record in ordered {
			guard case .synced(.reviewApplied(let body)) = record.body else { continue }
			segments[segmentIndex(for: record.ulid)].notes.append(
				ReviewNote(ulid: record.ulid, summary: body.summary))
		}
		for firstIncluded in legacyTrims {
			segments[segmentIndex(for: firstIncluded)].legacyTrim = firstIncluded
		}
		for record in ordered where record.deviceId == device {
			let index = segmentIndex(for: record.ulid)
			switch record.body {
			case .synced(.windowStart(let body)):
				switch body.reason {
				case .trim, .compaction:
					segments[index].promptWindow = PromptWindow(
						firstIncluded: body.firstIncludedUlid, opened: record.ulid)
				case .reset:
					continue
				}
			case .synced(.compactionSummary(let body)):
				segments[index].promptWindow.summarize(body, at: record.ulid)
			default:
				continue
			}
		}
		return Conversation(chat: chat, segments: segments, legacyMessageUlids: legacyMessages)
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
				next.segments[position.segment].turns[position.turn].claims.append(
					ClaimedAttempt(hlc: record.hlc, body: body))
			case .deviceLocal(.replyObserved(let body)):
				guard let position = next.position(of: body.turn) else { continue }
				next.segments[position.segment].turns[position.turn].replyObserved.append(body)
			case .synced(.reviewApplied(let body)):
				next.appendNote(ReviewNote(ulid: record.ulid, summary: body.summary))
			case .synced(.windowStart(let body)):
				guard case .reset(let kind) = body.reason else { continue }
				next.openSegment(at: body.firstIncludedUlid, openedBy: .reset(kind))
			default:
				continue
			}
		}
		return next
	}
}

extension Ledger {
	package func conversation(_ chat: ChatID) async throws(LedgerFailure) -> Conversation {
		let synced = try await read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chat))
		let local = try await read(RecordQuery(scope: ConversationFold.localScope, chatId: chat))
		return ConversationFold.fold(
			chat: chat, synced: synced.records, local: local.records, device: deviceId)
	}
}

package struct Conversation: Sendable, Equatable {
	package let chat: ChatID
	package var segments: [Segment]
	package var legacyMessageUlids: Set<ULID> = []

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

	package mutating func observeInMemory(_ turn: TurnID, attempt: AttemptID) {
		guard let position = position(of: turn) else { return }
		segments[position.segment].turns[position.turn].replyObserved.append(
			ReplyObservedBody(chatId: chat, turn: turn, attempt: attempt))
	}

	package mutating func settleInMemory(
		_ turn: TurnID, attempt: AttemptID, _ settlement: Settlement, ulid: ULID, now: Date,
		zone: TimeZone, device: DeviceID
	) {
		guard let position = position(of: turn) else { return }
		let facts = segments[position.segment].turns[position.turn]
		let last =
			(facts.fragments.map(\.hlc) + facts.claims.map(\.hlc)
			+ facts.settlements.map(\.hlc)).max()
		segments[position.segment].turns[position.turn].settlements.append(
			SettledAttempt(
				ulid: ulid,
				hlc: HybridLogicalClock.tick(now: now, deviceId: device, last: last),
				civilDate: CivilDate(date: now, timeZone: zone),
				attempt: attempt,
				settlement: settlement
			))
	}

	fileprivate mutating func appendToCurrent(_ facts: TurnFacts) {
		if segments.isEmpty {
			segments.append(Segment(id: SegmentID(boundary: nil), openedBy: .chatStart))
		}
		segments[segments.count - 1].turns.append(facts)
	}

	fileprivate mutating func appendNote(_ note: ReviewNote) {
		guard !segments.contains(where: { $0.notes.contains(note) }) else { return }
		if segments.isEmpty {
			segments.append(Segment(id: SegmentID(boundary: nil), openedBy: .chatStart))
		}
		segments[segments.count - 1].notes.append(note)
	}

	package func lastExchange(before turn: TurnID) -> LastExchange {
		let segment = current
		guard let running = segment.turns.first(where: { $0.turn == turn })?.firstFragment
		else { return .none }
		let stamps = segment.turns.filter { facts in
			facts.firstFragment.map { $0 < running } ?? false
		}.flatMap { $0.fragments.map(\.hlc) + $0.settlements.map(\.hlc) }
		guard let latest = stamps.max() else { return .none }
		return latest.wallMs > 0 ? .at(latest.wallTime) : .malformed
	}
}
