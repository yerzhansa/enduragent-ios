import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct MemoryQueryTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func newestDateFirst() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		_ = try await memory.appendEvent(
			date: "1998-06-13", kind: .decision, text: "Hold volume this week", source: .flush,
			stamp: testStamp())
		_ = try await memory.appendEvent(
			date: "1998-06-01", kind: .illness, text: "Easy week after a cold", source: .chat,
			stamp: testStamp())
		_ = try await memory.appendEvent(
			date: "1998-06-30", kind: .outcome, text: "Group ride felt strong", source: .chat,
			stamp: testStamp())
		let hits = try await memory.query(
			from: "1998-06-01", to: "1998-06-30", contains: nil, for: .unconnected)
		#expect(hits.map(\.date) == ["1998-06-30", "1998-06-13", "1998-06-01"])
	}

	@Test func queryRendersDailyThenEventThenHistory() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.appendDailyNote("Felt fresh on the morning spin.", stamp: testStamp())
		_ = try await memory.appendEvent(
			date: "1998-06-13",
			kind: .decision,
			text: "Hold volume this week",
			source: .flush, stamp: testStamp())
		try await memory.writeSection(
			.person, content: "- Name: Ada Kovač", source: .chat, stamp: testStamp())
		let hits = try await memory.query(
			from: "1998-06-13", to: "1998-06-13", contains: nil, for: .unconnected)
		#expect(hits.map(\.kind) == [.dailyNote, .ledger(.decision), .journal])
		let rendered = MemoryQuery.render(hits, from: "1998-06-13", to: "1998-06-13")
		#expect(rendered.contains("## 1998-06-13\nFelt fresh on the morning spin.\nevent: "))
		#expect(rendered.contains("history: "))
	}
}
