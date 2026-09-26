import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct MemoryTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func journalRecordPrecedesSectionRecord() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.writeSection(
			.person, content: "## Ada Kovač\nRides on Saturdays.", source: .chat, stamp: testStamp()
		)
		let records = try await store.fetch(
			RecordQuery(scope: .synced([.journal, .memorySection]))
		).records
			.sorted { $0.hlc < $1.hlc }
		#expect(records.count == 2)
		guard case .synced(.journal(let journal)) = records[0].body else {
			Issue.record("expected journal first")
			return
		}
		guard case .synced(.memorySection(let section)) = records[1].body else {
			Issue.record("expected section second")
			return
		}
		#expect(journal.op == .writeSection)
		#expect(records[0].hlc < records[1].hlc)
		#expect(section.name == .person)
		#expect(section.content.hasPrefix("_updated: 1998-06-13"))
		#expect(!section.content.contains("\n## "))
		#expect(section.content.contains("### Ada Kovač"))
		#expect(section.content.contains("_updated: 1998-06-13\n"))
		let stamps = section.content.split(separator: "\n").filter { $0.hasPrefix("_updated: ") }
		#expect(stamps.count == 1)
	}

	@Test func appendDailyNoteSkipsWholeLineDuplicateWithoutJournal() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.appendDailyNote("Felt fresh on the morning spin.", stamp: testStamp())
		try await memory.appendDailyNote("Felt fresh on the morning spin.", stamp: testStamp())
		try await memory.appendDailyNote("Knee felt fine on the evening spin.", stamp: testStamp())
		let notes = try await store.fetch(RecordQuery(scope: .synced([.dailyNote, .journal])))
			.records
		#expect(
			notes.filter { if case .synced(.dailyNote) = $0.body { true } else { false } }.count
				== 2)
		#expect(
			notes.filter { if case .synced(.journal) = $0.body { true } else { false } }.isEmpty)
	}

	@Test func appendEventReturnsFalseOnTwoDeviceDuplicate() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		let other = DeviceID(rawValue: "phone-b")
		let now = clock.now
		try await seed(
			store,
			[
				storedRecord(
					device: other,
					wall: Int64(now.timeIntervalSince1970 * 1000),
					body: .synced(
						.ledgerEvent(
							LedgerEventBody(
								date: "1998-06-13", kind: .decision, text: "Keep Saturdays free.",
								source: .chat)))
				)
			]
		)
		let recorded = try await memory.appendEvent(
			date: "1998-06-13",
			kind: .decision,
			text: "  Keep Saturdays   free.  ",
			source: .flush, stamp: testStamp())
		#expect(recorded == false)
		let events = try await store.fetch(RecordQuery(scope: .synced([.ledgerEvent]))).records
		#expect(events.count == 1)
	}

	@Test func contextInjectsOrphansAndStripsCompaction() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.writeSection(
			.person, content: "- Name: Ada Kovač", source: .chat, stamp: testStamp())
		try await memory.writeSection(
			.notes, content: "- Prefers hill repeats", source: .chat, stamp: testStamp())
		try await memory.writeSection(
			SectionName(rawValue: "random-legacy"),
			content: "stale orphan body",
			source: .chat,
			stamp: testStamp()
		)
		try await memory.appendDailyNote("Felt fresh on the morning spin.", stamp: testStamp())
		try await memory.appendDailyNote(
			"""
			### Compaction summary

			#### Athlete Profile
			- FTP 240W
			### End of compaction summary
			""", stamp: testStamp())
		try await memory.appendDailyNote("Knee felt fine on the evening spin.", stamp: testStamp())
		let context = try await memory.context()
		#expect(context.contains("## Athlete Memory"))
		#expect(context.contains("## person"))
		#expect(context.contains("Ada Kovač"))
		#expect(context.contains("## random-legacy"))
		#expect(context.contains("stale orphan body"))
		#expect(!context.contains("## notes"))
		#expect(context.contains("## Today's Notes"))
		#expect(context.contains("Felt fresh on the morning spin."))
		#expect(context.contains("Knee felt fine on the evening spin."))
		#expect(!context.contains("### Compaction summary"))
		#expect(!context.contains("FTP 240W"))
		#expect(!context.contains("## Current Plan"))
		let view = try await memory.view()
		#expect(view.orphanNames == ["random-legacy"])
		#expect(view.planHeadline == nil)
	}

	@Test func injectableDailyLinesDropsMarkersAndExitsOnH3() {
		let daily = [
			"Felt fresh on the morning spin.",
			"### Compaction summary",
			"",
			"#### Athlete Profile",
			"- FTP 240W",
			"### End of compaction summary",
			"Knee felt fine on the evening spin.",
			"### Compaction summary",
			"hidden inside skip",
			"## person",
			"kept after H2 exit",
		].joined(separator: "\n")
		#expect(
			injectableDailyLines(daily).joined(separator: "\n")
				== [
					"Felt fresh on the morning spin.",
					"Knee felt fine on the evening spin.",
					"## person",
					"kept after H2 exit",
				].joined(separator: "\n")
		)
	}

	@Test func writeSectionPropagatesJournalAppendFailure() async throws {
		let store = JournalRejectingLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		await #expect(throws: LedgerFailure.rejectedBatch) {
			try await memory.writeSection(
				.person, content: "- Name: Ada", source: .chat, stamp: testStamp())
		}
		let sections = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		#expect(sections.isEmpty)
	}

	@Test func writeSectionReplacesLeadingStampRatherThanStacking() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.writeSection(
			.person, content: "_updated: 1998-06-01\n- Name: Ada", source: .chat, stamp: testStamp()
		)
		let records = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		guard case .synced(.memorySection(let body)) = records.last?.body else {
			Issue.record("expected section")
			return
		}
		#expect(body.content == "_updated: 1998-06-13\n- Name: Ada")
	}
}

private struct JournalAppendRejected: Error, Equatable {}

private final class JournalRejectingLog: RecordLog, @unchecked Sendable {
	let inner = InMemoryRecordLog()
	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		if batch.contains(where: { if case .synced(.journal) = $0.body { true } else { false } }) {
			throw JournalAppendRejected()
		}
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
