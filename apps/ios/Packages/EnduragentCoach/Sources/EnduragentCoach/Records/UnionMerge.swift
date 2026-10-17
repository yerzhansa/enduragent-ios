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
}

private func inHLCOrder(_ records: [AthleteRecord]) -> [AthleteRecord] {
	records.sorted { $0.hlc < $1.hlc }
}
