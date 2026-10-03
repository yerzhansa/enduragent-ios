import Foundation

extension Conversation {
	package mutating func apply(_ records: [AthleteRecord], device: DeviceID) {
		let ordered = records.filter {
			$0.chatId == chat && ($0.locality != .deviceLocal || $0.deviceId == device)
				&& appliedRecordIDs.insert($0.ulid).inserted
		}.sorted { $0.hlc < $1.hlc }
		if segments.isEmpty {
			segments = [Segment(id: SegmentID(boundary: nil), openedBy: .chatStart)]
		}
		guard !ordered.isEmpty else { return }
		ownership = ownership.including(ordered)
		var turns = Dictionary(
			uniqueKeysWithValues: segments.flatMap(\.turns).map { ($0.turn, $0) })
		for record in ordered {
			switch record.body {
			case .synced(.userMessage(let body)):
				if turns[body.turn] == nil {
					turns[body.turn] = TurnFacts(
						turn: body.turn, chat: chat, origin: record.deviceId)
				}
				turns[body.turn]?.fragments.append(
					Fragment(
						ulid: record.ulid, hlc: record.hlc, civilDate: record.civilDate,
						timeZone: record.timeZone,
						index: body.fragment, draft: body.draft, text: body.athleteText,
						slash: body.slash, account: record.account))
			case .legacy(.userMessageV1(_, let text, let slash)):
				legacyMessageUlids.insert(record.ulid)
				let turn = TurnID(ulid: record.ulid)
				turns[turn] = TurnFacts(
					turn: turn, chat: chat, origin: record.deviceId, legacy: true,
					fragments: [
						Fragment(
							ulid: record.ulid, hlc: record.hlc, civilDate: record.civilDate,
							timeZone: record.timeZone,
							index: 0, draft: nil, text: text, slash: slash, account: record.account)
					])
			case .legacy(.assistantMessage):
				legacyMessageUlids.insert(record.ulid)
			default: break
			}
		}
		let legacyTurns = turns.values.filter(\.legacy).compactMap { facts in
			facts.fragments.first.map { (turn: facts.turn, origin: facts.origin, hlc: $0.hlc) }
		}.sorted { $0.hlc < $1.hlc }
		for record in ordered {
			if RecordQuery.Scope.synced([.reviewWrite, .reviewCancelledUnknown]).admits(record.body)
			{
				calendarRecords[record.ulid] = record
			}
			switch record.body {
			case .synced(.turnSettled(let body)), .deviceLocal(.pendingSettlement(let body)):
				turns[body.turn]?.settlements.append(
					SettledAttempt(
						ulid: record.ulid, hlc: record.hlc, attempt: body.attempt,
						settlement: body.settlement, origin: record.deviceId,
						account: record.account))
			case .legacy(.assistantMessage(let body)):
				guard
					let turn = legacyTurns.last(where: {
						$0.origin == record.deviceId && $0.hlc < record.hlc
					})?.turn
				else { continue }
				turns[turn]?.settlements.append(
					SettledAttempt(
						ulid: record.ulid, hlc: record.hlc, attempt: AttemptID(ulid: record.ulid),
						settlement: .replied(
							.model(body.text),
							lineage: ReplyLineage(
								templateHash: body.templateHash, assembledHash: body.assembledHash)),
						origin: record.deviceId, account: record.account))
			case .deviceLocal(.turnClaim(let body)):
				turns[body.turn]?.claims.append(
					ClaimedAttempt(hlc: record.hlc, body: body, account: record.account))
			case .deviceLocal(.replyObserved(let body)):
				turns[body.turn]?.replyObserved.append(body)
			case .synced(.reviewWrite(let body)):
				guard case .operation(.turn(let turn), _) = record.cause else { continue }
				let known = turns[turn]?.reviewWrites[body.key] ?? .notSent
				turns[turn]?.reviewWrites[body.key] = known.merging(body.evidence)
			case .synced(.reviewApplied(let body)):
				let index = segmentIndex(for: record.ulid, at: record.hlc)
				segments[index].notes.append(
					ReviewNote(
						ulid: record.ulid, hlc: record.hlc,
						date: record.civilDate, content: .applied(body.summary)))
				segments[index].notes.sort { $0.hlc < $1.hlc }
			case .legacy(.windowStartV1(_, let firstIncluded)):
				if legacyMessageUlids.contains(firstIncluded) {
					let hlc =
						turns.values.flatMap(\.fragments).first { $0.ulid == firstIncluded }?.hlc
						?? record.hlc
					segments[segmentIndex(for: firstIncluded, at: hlc)].legacyTrim = firstIncluded
				} else {
					openSegment(
						at: firstIncluded, boundary: .legacy(firstIncluded, recorded: record.hlc),
						openedBy: .legacyBoundary)
				}
			case .synced(.windowStart(let body)):
				switch body.reason {
				case .trim, .compaction:
					guard record.deviceId == device else { continue }
					let index = segmentIndex(for: record.ulid, at: record.hlc)
					let dropped =
						body.droppedMessageUlids
						?? turns.values.filter {
							$0.origin == device
								&& $0.userRow.map { $0.ulid < body.firstIncludedUlid } == true
								&& ($0.latestSettlement.map { $0.ulid < record.ulid } ?? true)
						}.flatMap { $0.messageRows.map(\.ulid) }
					let owner = ownership.rowOwner(account: record.account, origin: record.deviceId)
					let covered = (segments[index].promptWindows[owner]?.trim?.messageUlids ?? [])
						.union(dropped)
					segments[index].promptWindows[owner] = PromptWindow(
						trim: .init(messageUlids: covered, opened: record.ulid))
				case .reset(let reset):
					let boundary =
						body.boundaryClock.map(SegmentBoundary.observed)
						?? .legacy(body.firstIncludedUlid, recorded: record.hlc)
					openSegment(
						at: body.firstIncludedUlid, boundary: boundary, openedBy: .reset(reset))
				}
			case .synced(.compactionSummary(let body)) where record.deviceId == device:
				let index = segmentIndex(for: record.ulid, at: record.hlc)
				let owner = ownership.rowOwner(account: record.account, origin: record.deviceId)
				segments[index].promptWindows[owner, default: PromptWindow()].summarize(
					body, at: record.ulid)
			default: break
			}
		}
		for index in segments.indices { segments[index].turns = [] }
		let orderedTurns = turns.values.compactMap { facts in
			facts.fragments.min(by: { $0.index < $1.index }).map { (facts: facts, first: $0) }
		}.sorted { $0.first.hlc < $1.first.hlc }
		for (facts, first) in orderedTurns {
			segments[segmentIndex(for: first.ulid, at: first.hlc)].turns.append(facts)
		}
		guard !calendarRecords.isEmpty else { return }
		for index in segments.indices {
			segments[index].notes.removeAll {
				if case .cancelledUnknown = $0.content { return true }
				return false
			}
		}
		for marker in ReviewCancelledUnknownBody.validated(in: Array(calendarRecords.values)) {
			guard case .synced(.reviewCancelledUnknown(let body)) = marker.body else { continue }
			let turn: TurnID?
			if case .operation(.turn(let original), _) = marker.cause {
				turn = original
			} else {
				turn = nil
			}
			let anchor = turn.flatMap { turns[$0]?.fragments.min(by: { $0.index < $1.index }) }
			let index = segmentIndex(
				for: anchor?.ulid ?? marker.ulid, at: anchor?.hlc ?? marker.hlc)
			segments[index].notes.append(
				ReviewNote(
					ulid: marker.ulid, hlc: marker.hlc, date: marker.civilDate,
					content: .cancelledUnknown(CancelledUnknownReview(body)), after: turn))
			segments[index].notes.sort { $0.hlc < $1.hlc }
		}
	}

	func segmentIndex(for ulid: ULID, at hlc: HybridLogicalClock) -> Int {
		segments.lastIndex { $0.boundary.map { $0.includes(ulid, at: hlc) } ?? true } ?? 0
	}
}
