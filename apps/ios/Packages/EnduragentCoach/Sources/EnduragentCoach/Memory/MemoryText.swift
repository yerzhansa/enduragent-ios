import Foundation

public enum MemoryQuery {
	public static let maxRangeDays = 366
	public static let maxResultChars = 20_000
	public static let truncationNotice = "[truncated — narrow the date range or add a query term]"
	public static let emptySuffix = ": no daily notes, events, or history found."

	public static func render(
		_ hits: [MemoryHit], from: CivilDate, to: CivilDate, query: String? = nil
	) -> String {
		let header =
			"Memory query \(from.rawValue)..\(to.rawValue)"
			+ (query.map { " matching \"\($0)\"" } ?? "")
		if hits.isEmpty {
			return header + emptySuffix
		}
		var grouped: [(CivilDate, [MemoryHit])] = []
		for hit in hits {
			if grouped.last?.0 == hit.date {
				grouped[grouped.count - 1].1.append(hit)
			} else {
				grouped.append((hit.date, [hit]))
			}
		}
		let sections = grouped.map { date, rows in
			let lines = rows.map(renderLine)
			return "## \(date.rawValue)\n" + lines.joined(separator: "\n")
		}
		let result = ([header] + sections).joined(separator: "\n\n")
		if result.utf16.count > maxResultChars {
			return memoryTruncateUtf16(result, maxChars: maxResultChars) + "\n" + truncationNotice
		}
		return result
	}
}

struct MemorySnapshot {
	var sections: [AthleteRecord]
	var daily: [AthleteRecord]
	var ledgerRecords: [AthleteRecord]
	var journalRecords: [AthleteRecord]
	var compaction: [AthleteRecord]
	var orphanNames: [String]
	var planHeadline: PlanHeadline? { nil }

	func dailyNotesOnly(on date: CivilDate) -> String {
		daily.sorted { $0.hlc < $1.hlc }.compactMap { record -> String? in
			guard record.civilDate == date, case .dailyNote(let body) = record.body else {
				return nil
			}
			return body.note
		}.joined(separator: "\n")
	}

	func dailyText(on date: CivilDate) -> String {
		var notes = dailyNotesOnly(on: date)
		if notes.contains(MemoryFlushPolicy.compactionStart) {
			return notes
		}
		let extras = compaction.sorted { $0.hlc < $1.hlc }.compactMap { record -> String? in
			guard record.civilDate == date, case .compactionSummary(let body) = record.body else {
				return nil
			}
			return formatCompactionNote(body.markdown)
		}
		for extra in extras {
			notes = notes.isEmpty ? extra : notes + "\n" + extra
		}
		return notes
	}
}

struct JournalPreview {
	var section: String?
	var oldBody: String?
	var newBody: String?
}

func parseJournalPreview(_ preview: String) -> JournalPreview {
	do {
		let parsed = try JSONValue.parse(preview)
		let fields = parsed.objectFields
		return JournalPreview(
			section: fields["section"]?.stringValue,
			oldBody: fields["oldBody"]?.stringValue,
			newBody: fields["newBody"]?.stringValue
		)
	} catch is DecodingError {
		return JournalPreview(section: nil, oldBody: nil, newBody: preview)
	}
}

func demoteEmbeddedH2(_ content: String) -> String {
	content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
		let text = String(line)
		if text.hasPrefix("## ") {
			return "### " + text.dropFirst(3)
		}
		return text
	}.joined(separator: "\n")
}

func stampUpdated(_ content: String, date: CivilDate) -> String {
	var body = content
	if body.hasPrefix(MemoryFlushPolicy.stampPrefix) {
		if let newline = body.firstIndex(of: "\n") {
			body = String(body[body.index(after: newline)...])
		} else {
			body = ""
		}
	}
	if body.isEmpty {
		return MemoryFlushPolicy.stampPrefix + date.rawValue
	}
	return MemoryFlushPolicy.stampPrefix + date.rawValue + "\n" + body
}

func hasLogicalSectionContent(_ stamped: String) -> Bool {
	guard let newline = stamped.firstIndex(of: "\n") else { return false }
	return !stamped[stamped.index(after: newline)...]
		.trimmingCharacters(in: .whitespacesAndNewlines)
		.isEmpty
}

package func injectableDailyLines(_ daily: String) -> [String] {
	var inSummary = false
	var lines: [String] = []
	for raw in daily.split(separator: "\n", omittingEmptySubsequences: false) {
		let line = String(raw)
		let trimmed = memoryTrimEnd(line)
		if trimmed == MemoryFlushPolicy.compactionStart {
			inSummary = true
			continue
		}
		if trimmed == MemoryFlushPolicy.compactionEnd {
			inSummary = false
			continue
		}
		if inSummary, isAtMostH3(line) {
			inSummary = false
			lines.append(line)
			continue
		}
		if inSummary {
			continue
		}
		lines.append(line)
	}
	return lines
}

func isAtMostH3(_ line: String) -> Bool {
	line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
}

func formatCompactionNote(_ summary: String) -> String {
	let demoted = summary.split(separator: "\n", omittingEmptySubsequences: false).map {
		line -> String in
		let text = String(line)
		if text.hasPrefix("## "), !text.hasPrefix("### ") {
			return "#### " + text.dropFirst(3)
		}
		return text
	}.joined(separator: "\n")
	return
		MemoryFlushPolicy.compactionStart
		+ "\n\n"
		+ demoted
		+ "\n"
		+ MemoryFlushPolicy.compactionEnd
}

func eachDate(from: CivilDate, to: CivilDate) -> [CivilDate] {
	var dates: [CivilDate] = []
	var cursor = from
	while cursor <= to {
		dates.append(cursor)
		if cursor == to { break }
		cursor = cursor.adding(days: 1)
	}
	return dates
}

func kindOrder(_ kind: MemoryHit.Kind) -> Int {
	switch kind {
	case .dailyNote: return 0
	case .ledger: return 1
	case .journal: return 2
	}
}

func renderLine(_ hit: MemoryHit) -> String {
	switch hit.kind {
	case .dailyNote:
		return hit.text
	case .ledger:
		return "event: \(hit.text)"
	case .journal:
		return "history: \(hit.text)"
	}
}

func serializeLedger(_ record: AthleteRecord, body: LedgerEventBody) -> String {
	serializeLedgerLine(
		date: record.civilDate,
		kind: body.kind,
		text: body.text,
		source: body.source,
		wallMs: record.hlc.wallMs
	)
}

func serializeLedgerLine(
	date: CivilDate,
	kind: LedgerKind,
	text: String,
	source: LedgerSource,
	wallMs: Int64
) -> String {
	let ts = isoFromWallMs(wallMs)
	return
		"{\"ts\":\(JSONValue.string(ts).canonicalDigestInput()),"
		+ "\"date\":\(JSONValue.string(date.rawValue).canonicalDigestInput()),"
		+ "\"kind\":\(JSONValue.string(kind.rawValue).canonicalDigestInput()),"
		+ "\"text\":\(JSONValue.string(text).canonicalDigestInput()),"
		+ "\"source\":\(JSONValue.string(source.rawValue).canonicalDigestInput())}"
}

func isoFromWallMs(_ wallMs: Int64) -> String {
	let date = Date(timeIntervalSince1970: TimeInterval(wallMs) / 1000)
	return GregorianStamp.isoMillis(date)
}

func wallMs(_ date: Date) -> Int64 {
	Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
}

func historyBodySummary(_ body: String?, query: String?) -> String {
	let text = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacing(
		/\s+/, with: " ")
	if text.utf16.count <= MemoryFlushPolicy.historyPreviewChars {
		return text
	}
	let lowered = text.lowercased()
	let match = query.flatMap { lowered.range(of: $0)?.lowerBound }
	guard let query, let match else {
		return memoryTruncateUtf16(text, maxChars: MemoryFlushPolicy.historyPreviewChars)
	}
	let utf16 = Array(text.utf16)
	let queryUnits = Array(query.utf16)
	let matchIndex = lowered.utf16.distance(from: lowered.utf16.startIndex, to: match)
	var start = max(
		0,
		min(
			matchIndex + queryUnits.count / 2 - MemoryFlushPolicy.historyPreviewChars / 2,
			utf16.count - MemoryFlushPolicy.historyPreviewChars
		)
	)
	if start < utf16.count {
		let unit = utf16[start]
		if (0xDC00...0xDFFF).contains(unit), start > 0 {
			start -= 1
		}
	}
	let window = memoryTruncateUtf16(
		String(utf16CodeUnits: Array(utf16.suffix(from: start)), count: utf16.count - start),
		maxChars: MemoryFlushPolicy.historyPreviewChars
	)
	let leading = start > 0 ? "…" : ""
	let trailing = start + window.utf16.count < utf16.count ? "…" : ""
	return "\(leading)\(window)\(trailing)"
}

func memoryWireMessage(from message: ChatMessage) -> WireMessage {
	WireMessage(
		role: message.role == .user ? .user : .assistant,
		content: message.text,
		toolCalls: [],
		toolCallId: nil
	)
}

func memoryTruncateUtf16(_ text: String, maxChars: Int) -> String {
	if maxChars <= 0 {
		return ""
	}
	let units = Array(text.utf16)
	if units.count <= maxChars {
		return text
	}
	var cut = maxChars
	let prev = units[maxChars - 1]
	if (0xD800...0xDBFF).contains(prev), maxChars > 1 {
		cut = maxChars - 1
	}
	return String(utf16CodeUnits: Array(units.prefix(cut)), count: cut)
}

func memoryTrimEnd(_ text: String) -> String {
	var end = text.endIndex
	while end > text.startIndex {
		let prev = text.index(before: end)
		if text[prev].isWhitespace {
			end = prev
		} else {
			break
		}
	}
	return String(text[..<end])
}
