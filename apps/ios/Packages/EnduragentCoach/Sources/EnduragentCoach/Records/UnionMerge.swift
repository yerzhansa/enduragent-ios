import Foundation

package enum UnionMerge {
	package static func sectionText(_ records: [AthleteRecord], name: SectionName) -> String? {
		inHLCOrder(records).reversed().compactMap { record -> String? in
			guard case .synced(.memorySection(let body)) = record.body, body.name == name else {
				return nil
			}
			return body.content
		}.first
	}

	package static func ledger(_ records: [AthleteRecord]) -> [AthleteRecord] {
		var seen: Set<String> = []
		var events: [AthleteRecord] = []
		for record in inHLCOrder(records) {
			guard case .synced(.ledgerEvent(let body)) = record.body else { continue }
			let digest = ledgerDigest(date: body.date, kind: body.kind, text: body.text)
			if seen.insert(digest).inserted {
				events.append(record)
			}
		}
		return events
	}

	package static func ledgerDigest(date: CivilDate, kind: LedgerKind, text: String) -> String {
		let normalized = text.replacing(/^[\s]+|[\s]+$/, with: "").replacing(/\s+/, with: " ")
			.lowercased()
		let input = JSONValue.array([
			.string(date.rawValue), .string(kind.rawValue), .string(normalized),
		]).canonicalDigestInput()
		return sha256Hex(input)
	}

	package static func pendingProposal(
		_ records: [AthleteRecord],
		chatId: ChatID,
		now: Date
	) -> ProposalBody? {
		pendingProposalRecord(records, chatId: chatId, now: now)?.body
	}

	package static func pendingProposalRecord(
		_ records: [AthleteRecord],
		chatId: ChatID,
		now: Date
	) -> LiveProposal? {
		let ordered = inHLCOrder(records)
		var clearedAt: [Nonce: HybridLogicalClock] = [:]
		for record in ordered {
			if case .deviceLocal(.proposalCleared(let body)) = record.body, body.chatId == chatId {
				clearedAt[body.nonce] = record.hlc
			}
		}
		for record in ordered.reversed() {
			guard case .deviceLocal(.pendingProposal(let body)) = record.body, body.chatId == chatId
			else {
				continue
			}
			if body.expiresAt <= now { continue }
			if let cleared = clearedAt[body.nonce], record.hlc < cleared { continue }
			return LiveProposal(
				cause: record.cause, body: body, account: record.account, ulid: record.ulid)
		}
		return nil
	}
}

private func inHLCOrder(_ records: [AthleteRecord]) -> [AthleteRecord] {
	records.sorted { $0.hlc < $1.hlc }
}
