import Foundation

public struct Memory: Sendable {
	let store: any RecordLog
	let clock: any Clock

	public init(store: any RecordLog, clock: any Clock) {
		self.store = store
		self.clock = clock
	}

	public func query(from: CivilDate, to: CivilDate, contains: String?) async throws -> [MemoryHit]
	{
		if from > to {
			throw MemoryQueryFailure(
				message:
					"Error: 'from' (\(from.rawValue)) is after 'to' (\(to.rawValue)). Swap the bounds."
			)
		}
		let days = IntervalsPolicy.inclusiveDayCount(from: from, to: to)
		if days > MemoryQuery.maxRangeDays {
			throw MemoryQueryFailure(
				message:
					"Error: range is \(days) days; the maximum is \(MemoryQuery.maxRangeDays). Query a narrower range."
			)
		}
		let snapshot = try await loadSnapshot()
		let needle = contains?.lowercased()
		var collected: [(hit: MemoryHit, order: Int)] = []
		var order = 0

		for date in eachDate(from: from, to: to) {
			let text = snapshot.dailyText(on: date)
			if text.isEmpty { continue }
			if let needle {
				let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
					.filter { $0.lowercased().contains(needle) }
					.map(String.init)
				if lines.isEmpty { continue }
				collected.append(
					(
						MemoryHit(
							date: date, kind: .dailyNote, text: lines.joined(separator: "\n")),
						order
					)
				)
			} else {
				collected.append((MemoryHit(date: date, kind: .dailyNote, text: text), order))
			}
			order += 1
		}

		for record in snapshot.ledgerRecords {
			guard record.civilDate >= from, record.civilDate <= to else { continue }
			guard case .ledgerEvent(let body) = record.body else { continue }
			let line = serializeLedger(record, body: body)
			if let needle, !line.lowercased().contains(needle) { continue }
			collected.append(
				(MemoryHit(date: record.civilDate, kind: .ledger(body.kind), text: line), order)
			)
			order += 1
		}

		for record in snapshot.journalRecords {
			guard record.civilDate >= from, record.civilDate <= to else { continue }
			guard case .journal(let body) = record.body else { continue }
			let parsed = parseJournalPreview(body.preview)
			let section = parsed.section
			let oldBody = parsed.oldBody
			let newBody = parsed.newBody ?? body.preview
			if let needle {
				let haystacks = [section, oldBody, newBody]
				if !haystacks.contains(where: { $0?.lowercased().contains(needle) == true }) {
					continue
				}
			}
			let summary = historyBodySummary(section ?? body.op.rawValue, query: needle)
			let was = historyBodySummary(oldBody, query: needle)
			let now = historyBodySummary(newBody, query: needle)
			collected.append(
				(
					MemoryHit(
						date: record.civilDate,
						kind: .journal,
						text: "\(summary) — was: \(was) / now: \(now)"
					),
					order
				)
			)
			order += 1
		}

		return collected.sorted { lhs, rhs in
			if lhs.hit.date != rhs.hit.date {
				return lhs.hit.date > rhs.hit.date
			}
			let leftKind = kindOrder(lhs.hit.kind)
			let rightKind = kindOrder(rhs.hit.kind)
			if leftKind != rightKind {
				return leftKind < rightKind
			}
			return lhs.order < rhs.order
		}.map(\.hit)
	}

	public func context() async throws -> String {
		try await renderContext(
			excluding: SectionName.cyclingEffective.filter { !$0.inject }.map(\.rawValue))
	}

	package func fullContext() async throws -> String {
		try await renderContext(excluding: [])
	}

	package func complementContext() async throws -> String {
		let injected = SectionName.cyclingEffective.filter(\.inject).map(\.rawValue)
		return try await renderContext(excluding: injected)
	}

	public func writeSection(_ name: SectionName, content: String, source: LedgerSource)
		async throws
	{
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let snapshot = try await loadSnapshot()
		let previous = UnionMerge.sectionText(snapshot.sections, name: name)
		let stamped = stampUpdated(demoteEmbeddedH2(content), date: today)
		_ = MemoryFlushPolicy.sectionSoftWarnChars
		let digestBody = memoryTrimEnd(stamped)
		let logical = hasLogicalSectionContent(stamped)
		let provenance = ProvenanceBody(
			key: "memory:\(name.rawValue)",
			garmin: false,
			nonGarmin: false,
			unknown: logical,
			contentSha256: sha256Hex(digestBody)
		)
		try await append(.provenance(provenance), civilDate: today)
		let preview = JSONValue.object([
			"newBody": .string(stamped),
			"oldBody": previous.map(JSONValue.string) ?? .null,
			"section": .string(name.rawValue),
			"source": .string(source.rawValue),
		]).canonicalDigestInput()
		try await append(
			.journal(JournalBody(op: .writeSection, preview: preview)), civilDate: today)
		try await append(
			.memorySection(MemorySectionBody(name: name, content: stamped)), civilDate: today)
	}

	public func appendDailyNote(_ note: String) async throws {
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let snapshot = try await loadSnapshot()
		let existing = snapshot.dailyNotesOnly(on: today)
		if !existing.isEmpty, "\n\(existing)\n".contains("\n\(note)\n") {
			return
		}
		try await append(.dailyNote(DailyNoteBody(note: note)), civilDate: today)
	}

	public func appendEvent(date: CivilDate, kind: LedgerKind, text: String, source: LedgerSource)
		async throws -> Bool
	{
		let snapshot = try await loadSnapshot()
		let digest = UnionMerge.ledgerDigest(date: date, kind: kind, text: text)
		for record in snapshot.ledgerRecords {
			guard case .ledgerEvent(let body) = record.body else { continue }
			if UnionMerge.ledgerDigest(date: record.civilDate, kind: body.kind, text: body.text)
				== digest
			{
				return false
			}
		}
		let body = LedgerEventBody(kind: kind, text: text, source: source)
		let line = serializeLedgerLine(
			date: date, kind: kind, text: text, source: source, wallMs: wallMs(clock.now))
		try await append(
			.provenance(
				ProvenanceBody(
					key: "ledger:\(sha256Hex(line))",
					garmin: false,
					nonGarmin: false,
					unknown: true,
					contentSha256: sha256Hex(line)
				)
			),
			civilDate: date
		)
		try await append(.ledgerEvent(body), civilDate: date)
		return true
	}

	public func flush(trigger: FlushTrigger, chatId: ChatID, transport: any ModelTransport)
		async throws
	{
		let pending = try await oldestUnconsumedFlush(chatId: chatId)
		let effectiveTrigger: FlushTrigger = {
			if let pending, case .flushPending(let body) = pending.body {
				return body.trigger
			}
			return trigger
		}()
		let conversation = try await loadFlushMessages(
			trigger: effectiveTrigger, chatId: chatId, pending: pending)
		if conversation.isEmpty, pending == nil {
			return
		}
		var attempt = 0
		var lastWrites = 0
		var lastLedger = 0
		while attempt < MemoryFlushPolicy.maxAttempts {
			attempt += 1
			let outcome = try await runFlushGenerate(
				conversation: conversation, transport: transport)
			lastWrites = outcome.writes
			lastLedger = outcome.ledgerAppends
			let zeroWrite =
				outcome.writes == 0
				&& outcome.ledgerAppends == 0
				&& conversation.count >= MemoryFlushPolicy.flushZeroWriteMinMessages
			if effectiveTrigger == .staleReset, zeroWrite, attempt < MemoryFlushPolicy.maxAttempts {
				continue
			}
			break
		}
		_ = lastWrites
		_ = lastLedger
		if let pending {
			try await markConsumed(pending)
		}
	}

	public func view() async throws -> MemoryView {
		let snapshot = try await loadSnapshot()
		var sections: [String: String] = [:]
		for name in SectionName.cyclingEffective {
			if let content = UnionMerge.sectionText(snapshot.sections, name: name) {
				sections[name.rawValue] = content
			}
		}
		for orphan in snapshot.orphanNames {
			if let content = UnionMerge.sectionText(
				snapshot.sections, name: SectionName(rawValue: orphan))
			{
				sections[orphan] = content
			}
		}
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let notes = injectableDailyLines(snapshot.dailyText(on: today)).joined(separator: "\n")
		let trimmed = memoryTrimEnd(notes)
		return MemoryView(
			sections: sections,
			todayNotes: trimmed.isEmpty ? nil : trimmed,
			planHeadline: nil,
			orphanNames: snapshot.orphanNames
		)
	}

	package func hiddenSectionsHaveLogicalContent() async throws -> Bool {
		let snapshot = try await loadSnapshot()
		for name in SectionName.cyclingEffective where !name.inject {
			if let content = UnionMerge.sectionText(snapshot.sections, name: name),
				hasLogicalSectionContent(content)
			{
				return true
			}
		}
		return false
	}

	private func renderContext(excluding: [String]) async throws -> String {
		let snapshot = try await loadSnapshot()
		let exclude = Set(excluding)
		var parts: [String] = []
		var blocks: [String] = []
		for name in SectionName.cyclingEffective
		where name.inject && !exclude.contains(name.rawValue) {
			if let content = UnionMerge.sectionText(snapshot.sections, name: name), !content.isEmpty
			{
				blocks.append("## \(name.rawValue)\n\(content)")
			}
		}
		for orphan in snapshot.orphanNames where !exclude.contains(orphan) {
			if let content = UnionMerge.sectionText(
				snapshot.sections, name: SectionName(rawValue: orphan)),
				!content.isEmpty
			{
				blocks.append("## \(orphan)\n\(content)")
			}
		}
		if !blocks.isEmpty {
			parts.append("## Athlete Memory\n" + blocks.joined(separator: "\n\n") + "\n")
		}
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let daily = injectableDailyLines(snapshot.dailyText(on: today)).joined(separator: "\n")
		if !memoryTrimEnd(daily).isEmpty {
			parts.append("## Today's Notes\n" + daily)
		}
		if let headline = snapshot.planHeadline {
			var lines: [String] = []
			lines.append("- Name: \(headline.name)")
			if let goal = headline.primaryGoal {
				lines.append("- Goal: \(goal)")
			}
			if let weeks = headline.totalWeeks {
				lines.append("- Duration: \(weeks) weeks")
			}
			if let status = headline.status {
				lines.append("- Status: \(status.rawValue)")
			}
			if !lines.isEmpty {
				parts.append("## Current Plan\n" + lines.joined(separator: "\n"))
			}
		}
		return parts.joined(separator: "\n\n")
	}

}
