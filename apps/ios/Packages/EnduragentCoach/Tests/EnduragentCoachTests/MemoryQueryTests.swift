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

	@Test func aSaveAndItsReplacementShowAsHistoryWithNpmsPreviewsAndNoReviewDoes() async throws {
		let store = InMemoryRecordLog()
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let phone = store.deviceId
		let base: JSONValue = .object(["name": .string("Base Block"), "totalWeeks": .number(8)])
		let build: JSONValue = .object([
			"name": .string("Build Block"),
			"notes": .string(
				"Two threshold days each week, one long endurance ride on Sunday, and a recovery week after every third week of building load, finishing with sweet spot blocks before the race."
			),
			"totalWeeks": .number(12),
		])
		try await seed(
			store,
			[
				storedRecord(
					device: phone, wall: 10, date: "1998-06-12", ulid: fixedUlid(10),
					body: try SavedPlanRows.body(
						base, id: 1, confirmation: 2,
						decided: HybridLogicalClock(wallMs: 5, logical: 0, deviceId: phone))),
				storedRecord(
					device: phone, wall: 20, ulid: fixedUlid(20),
					body: try SavedPlanRows.body(
						build, id: 3, confirmation: 4,
						decided: HybridLogicalClock(wallMs: 8, logical: 0, deviceId: phone))),
				storedRecord(
					device: phone, wall: 30, ulid: fixedUlid(30),
					body: .deviceLocal(
						.workoutReview(
							WorkoutReviewBody(
								review: try reviewFixture("workout-review-unconfirmed"))))
				),
				storedRecord(
					device: phone, wall: 40, ulid: fixedUlid(40),
					body: try PlanStepRows(confirmation: 5, turn: 6).prepared(
						.object(["name": .string("Draft Block")]),
						expiresAt: Date(timeIntervalSince1970: 897_984_600))),
			])
		let offered = makeOfferedTools(
			intervals: FakeIntervalsClient(athleteName: "Ada", ftp: 250), ledger: ledger,
			clock: clock)
		let baseText = #"{ "name": "Base Block", "totalWeeks": 8 }"#
		let buildText =
			#"{ "name": "Build Block", "notes": "Two threshold days each week, one long endurance ride on Sunday, and a recovery week after every third week of building load, finishing with sweet spot blocks before"#
		let buildAroundSweetSpot =
			#"…": "Two threshold days each week, one long endurance ride on Sunday, and a recovery week after every third week of building load, finishing with sweet spot blocks before the race.", "totalWeeks": 12 }"#

		let everything = try await query(offered, nil)
		let either = try await query(offered, "BASE block")
		let replacementOnly = try await query(offered, "sweet spot")
		let unsaved = try await query(offered, "Draft Block")

		#expect(
			everything == """
				Memory query 1998-06-12..1998-06-13

				## 1998-06-13
				history: save-plan — was: \(baseText) / now: \(buildText)

				## 1998-06-12
				history: save-plan — was:  / now: \(baseText)
				""")
		#expect(
			either == """
				Memory query 1998-06-12..1998-06-13 matching "BASE block"

				## 1998-06-13
				history: save-plan — was: \(baseText) / now: \(buildText)

				## 1998-06-12
				history: save-plan — was:  / now: \(baseText)
				""")
		#expect(
			replacementOnly == """
				Memory query 1998-06-12..1998-06-13 matching "sweet spot"

				## 1998-06-13
				history: save-plan — was: \(baseText) / now: \(buildAroundSweetSpot)
				""")
		#expect(
			unsaved
				== #"Memory query 1998-06-12..1998-06-13 matching "Draft Block": no daily notes, events, or history found."#
		)
	}

	@Test func plansAndSectionWritesOfOneDayShowInTheOrderTheyHappened() async throws {
		let store = InMemoryRecordLog()
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let phone = store.deviceId
		let goals = JSONValue.object([
			"newBody": .string("Ride a century in June"),
			"oldBody": .null,
			"section": .string("goals"),
			"source": .string("chat"),
		]).canonicalDigestInput()
		try await seed(
			store,
			[
				storedRecord(
					device: phone, wall: 12, ulid: fixedUlid(12),
					body: try SavedPlanRows.body(
						.object(["name": .string("Base Block"), "totalWeeks": .number(8)]),
						id: 1, confirmation: 2,
						decided: HybridLogicalClock(wallMs: 11, logical: 0, deviceId: phone))),
				storedRecord(
					device: phone, wall: 20, ulid: fixedUlid(20),
					body: .synced(.journal(JournalBody(op: .writeSection, preview: goals)))),
				storedRecord(
					device: phone, wall: 32, ulid: fixedUlid(32),
					body: try SavedPlanRows.body(
						.object(["name": .string("Build Block"), "totalWeeks": .number(12)]),
						id: 3, confirmation: 4,
						decided: HybridLogicalClock(wallMs: 31, logical: 0, deviceId: phone))),
			])
		let offered = makeOfferedTools(
			intervals: FakeIntervalsClient(athleteName: "Ada", ftp: 250), ledger: ledger,
			clock: clock)
		let baseText = #"{ "name": "Base Block", "totalWeeks": 8 }"#
		let buildText = #"{ "name": "Build Block", "totalWeeks": 12 }"#

		#expect(
			try await query(offered, nil) == """
				Memory query 1998-06-12..1998-06-13

				## 1998-06-13
				history: save-plan — was:  / now: \(baseText)
				history: goals — was:  / now: Ride a century in June
				history: save-plan — was: \(baseText) / now: \(buildText)
				""")
	}

	private func query(_ offered: OfferedTools, _ needle: String?) async throws -> String {
		var arguments: [String: JSONValue] = [
			"from": .string("1998-06-12"), "to": .string("1998-06-13"),
		]
		arguments["query"] = needle.map(JSONValue.string)
		let execution = try await offered.execute(
			name: .memoryQuery, arguments: .object(arguments),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero))
		guard case .result(let envelope) = execution.outcome else {
			throw PlanFixtureFailure(description: "memory_query answered \(execution.outcome)")
		}
		return try #require(envelope.objectFields["data"]?.stringValue)
	}
}
