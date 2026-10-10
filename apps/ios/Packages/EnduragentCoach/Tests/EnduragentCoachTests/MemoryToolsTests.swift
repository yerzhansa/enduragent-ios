import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct MemoryToolsTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func memoryReadOmittedWhenNotesAreStampOnly() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.writeSection(.notes, content: "", source: .chat, stamp: testStamp())
		let view = try await memory.prompt(for: .unconnected).view
		let schemas = ToolCatalog.schemas(memory: view)
		#expect(!schemas.map(\.name).contains(.memoryRead))
		try await memory.writeSection(
			.notes, content: "- Prefers hill repeats", source: .chat, stamp: testStamp())
		let withNotes = try await memory.prompt(for: .unconnected).view
		let offered = ToolCatalog.schemas(memory: withNotes)
		#expect(offered.map(\.name).contains(.memoryRead))
	}

	@Test func ledgerAppendReportsACommitOnlyWhenRecorded() async throws {
		let store = InMemoryRecordLog()
		let tools = runtime(store: store)
		let arguments = try JSONValue.parse(
			#"{"date":"1998-06-13","kind":"decision","text":"Rides with a group on Saturdays"}"#
		)
		let first = try await tools.execute(
			name: .ledgerAppend, arguments: arguments, chatId: .main, scope: turnScope())
		let second = try await tools.execute(
			name: .ledgerAppend, arguments: arguments, chatId: .main, scope: turnScope())
		#expect(unwrap(first.outcome).objectFields["recorded"]?.boolValue == true)
		#expect(first.commit == CommittedWrite(tool: .ledgerAppend))
		#expect(unwrap(second.outcome).objectFields["recorded"]?.boolValue == false)
		#expect(unwrap(second.outcome).objectFields["duplicate"]?.boolValue == true)
		#expect(second.commit == nil)
	}

	@Test func memoryWriteReportsACommitOnlyAfterARecordIsSaved() async throws {
		let store = InMemoryRecordLog()
		let tools = runtime(store: store)
		let section = try await tools.execute(
			name: .memoryWrite,
			arguments: try JSONValue.parse(
				#"{"type":"memory","section":"schedule","content":"Rides on Saturdays"}"#),
			chatId: .main,
			scope: turnScope()
		)
		let refused = try await tools.execute(
			name: .memoryWrite,
			arguments: try JSONValue.parse(
				#"{"type":"memory","section":"nonsense","content":"Rides on Saturdays"}"#),
			chatId: .main,
			scope: turnScope()
		)
		let daily = try JSONValue.parse(#"{"type":"daily","content":"Group ride on Saturdays"}"#)
		let note = try await tools.execute(
			name: .memoryWrite, arguments: daily, chatId: .main, scope: turnScope())
		let repeated = try await tools.execute(
			name: .memoryWrite, arguments: daily, chatId: .main, scope: turnScope())
		#expect(section.commit == CommittedWrite(tool: .memoryWrite))
		#expect(refused.commit == nil)
		#expect(note.commit == CommittedWrite(tool: .memoryWrite))
		#expect(repeated.commit == nil)
		let sections = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		let notes = try await store.fetch(RecordQuery(scope: .synced([.dailyNote]))).records
		#expect(sections.count == 1)
		#expect(notes.count == 1)
	}

	@Test func memoryWriteAcceptsOrphanName() async throws {
		let store = InMemoryRecordLog()
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.writeSection(
			SectionName(rawValue: "random-legacy"), content: "stale orphan body", source: .chat,
			stamp: testStamp())
		let tools = runtime(store: store)
		let view = try await memory.prompt(for: .unconnected).view
		let schema = ToolCatalog.schemas(memory: view).first {
			$0.name == .memoryWrite
		}
		let encoded = canonicalJSON(schema?.parameters ?? .null)
		#expect(encoded.contains("random-legacy"))
		let result = try await tools.execute(
			name: .memoryWrite,
			arguments: try JSONValue.parse(
				#"{"type":"memory","section":"random-legacy","content":"updated orphan"}"#
			),
			chatId: .main,
			scope: turnScope()
		).outcome
		#expect(unwrap(result).objectFields["saved"]?.boolValue == true)
	}

	@Test func memoryWriteDailyAppendsToday() async throws {
		let store = InMemoryRecordLog()
		let result = try await runtime(store: store).execute(
			name: .memoryWrite,
			arguments: try JSONValue.parse(
				#"{"type":"daily","content":"Group ride on Saturdays"}"#),
			chatId: .main,
			scope: turnScope()
		).outcome
		#expect(unwrap(result).objectFields["saved"]?.boolValue == true)
		let notes = try await store.fetch(RecordQuery(scope: .synced([.dailyNote]))).records
		#expect(notes.count == 1)
	}

	private func unwrap(_ outcome: ToolOutcome) -> JSONValue {
		guard case .result(let json) = outcome else { return .null }
		return json.objectFields["data"] ?? json
	}

	private func runtime(store: InMemoryRecordLog = InMemoryRecordLog()) -> ToolRuntime {
		makeToolRuntime(
			intervals: intervals,
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		)
	}

	private func turnScope() -> TurnScope {
		TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
	}
}
