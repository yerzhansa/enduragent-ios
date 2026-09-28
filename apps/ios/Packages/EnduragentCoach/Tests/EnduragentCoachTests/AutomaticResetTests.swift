import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct AutomaticResetTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	func coach(at clock: FixedClock, over log: (any RecordLog)? = nil) -> Coach {
		makeCoach(transport: transport, store: log ?? store, clock: clock)
	}

	func answer(_ replies: String...) {
		transport.script = replies.flatMap { [ScriptedEvent.text($0), .finish(reason: .stop)] }
	}

	func records(_ scope: RecordQuery.Scope) async throws -> [AthleteRecord] {
		try await store.fetch(RecordQuery(scope: scope, chatId: .main)).records
			.sorted { $0.hlc < $1.hlc }
	}

	@Test func overnightBreakOpensANewConversationAtTheTurnThatCrossedIt() async throws {
		let clock = FixedClock(now: "1998-06-15T20:00:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		answer("Two rides.", "Rest today.")
		_ = try await coach.sendAndSettle("How was my week?")
		clock.advance(by: 13 * 3_600)
		_ = try await coach.sendAndSettle("What now?")
		let asked = try await records(.synced([.userMessage])).map(\.ulid)
		let answered = try await records(.synced([.turnSettled])).map(\.ulid)
		try #require(asked.count == 2 && answered.count == 2)
		#expect(
			try await records(.synced([.windowStart])).map(\.body) == [
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: asked[1], reason: .reset(.daily))))
			])
		let jobs = try await records(.deviceLocal([.flushPending])).compactMap {
			record -> FlushPendingBody? in
			guard case .deviceLocal(.flushPending(let body)) = record.body else { return nil }
			return body
		}
		try #require(jobs.count == 1)
		#expect(jobs[0].trigger == .staleReset)
		#expect(jobs[0].messageUlids == [asked[0], answered[0]])
		#expect(await coach.transcript(.main) == ["What now?", "Rest today."])
		let archived = try await coach.history()
		#expect(archived.map(\.reason) == [.closedAfterBreak])
		#expect(archived.first?.turns.map(\.athleteText) == ["How was my week?"])
	}

	@Test func theStaleResetJobStartsWithTheOutstandingRows() async throws {
		let clock = FixedClock(now: "1998-06-16T09:00:00+02:00", timeZone: "Europe/Amsterdam")
		let process = ProcessID(ulid: ULID.generate(at: clock.now))
		let evening = clock.now.addingTimeInterval(-13 * 3_600)
		var rows: [ULID] = []
		var records: [AthleteRecord] = []
		for (index, minutes) in [0.0, 10.0].enumerated() {
			let asked = evening.addingTimeInterval(minutes * 60)
			let question = ULID.generate(at: asked)
			let reply = ULID.generate(at: asked.addingTimeInterval(1))
			let turn = TurnID(ulid: question)
			rows += [question, reply]
			records += [
				seededRecord(
					store, at: asked, ulid: question,
					body: .synced(sampleUser(chatId: .main, text: "Question \(index)", turn: turn))),
				seededRecord(
					store, at: asked.addingTimeInterval(1), ulid: reply,
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Answer \(index)"))),
			]
		}
		let pending = ULID.generate(at: evening.addingTimeInterval(120))
		let running = ULID.generate(at: clock.now)
		let turn = TurnID(ulid: running)
		records += [
			seededRecord(
				store, at: evening.addingTimeInterval(120), ulid: pending,
				body: .deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, trigger: .softThreshold,
							messageUlids: Array(rows[0...1]),
							process: process)))),
			seededRecord(
				store, at: clock.now, ulid: running,
				body: .synced(sampleUser(chatId: .main, text: "What now?", turn: turn))),
		]
		try await seed(store, records)
		let diagnostics = DiagnosticsLog(clock: clock)
		let ledger = Ledger(log: store, clock: clock, diagnostics: diagnostics)
		let flushes = FlushWork(
			chat: .main, process: process, ledger: ledger,
			memory: Memory(ledger: ledger, clock: clock),
			transport: transport, clock: clock, diagnostics: diagnostics)
		let conversation = try await ledger.conversation(.main)
		#expect(
			FlushJob.outstanding(await flushes.jobs(in: conversation), in: conversation).map(
				\.messages)
				== [Array(rows[0...1])])
		let reset = await AutomaticReset(
			chat: .main, ledger: ledger, flushes: flushes, clock: clock
		)
		.run(
			before: turn, in: conversation, session: .npmDefaults,
			stamp: .turn(turn, attempt: AttemptID(ulid: ULID.generate(at: clock.now)), clock: clock)
		)
		#expect(reset?.kind == .daily)
		let outstanding = FlushJob.outstanding(
			await flushes.jobs(in: conversation), in: conversation)
		#expect(outstanding.map(\.trigger) == [.staleReset])
		#expect(outstanding.map(\.messages) == [rows])
	}

	@Test func recentExchangeAcrossTheResetHourKeepsTheConversation() async throws {
		let clock = FixedClock(now: "1998-06-16T03:50:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		answer("Two rides.", "Rest today.")
		_ = try await coach.sendAndSettle("How was my week?")
		clock.advance(by: 20 * 60)
		_ = try await coach.sendAndSettle("What now?")
		#expect(try await records(.synced([.windowStart])).isEmpty)
		#expect(
			await coach.transcript(.main) == [
				"How was my week?", "Two rides.", "What now?", "Rest today.",
			])
		#expect(try await coach.history().isEmpty)
	}

	@Test func theResetNoticeShowsOnceAndTheModelHearsOfItOnlyOnTheResetTurn() async throws {
		let clock = FixedClock(now: "1998-06-16T03:40:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		answer("Two rides.", "Rest today.", "Easy spin.")
		_ = try await coach.sendAndSettle("How was my week?")
		#expect(await coach.currentSnapshot(.main)?.opening == .continuing)
		clock.advance(by: 40 * 60)
		_ = try await coach.sendAndSettle("What now?")
		let reset = try #require(await coach.currentSnapshot(.main))
		#expect(reset.opening == .afterAutomaticReset(.daily))
		#expect(reset.opening.notice == Catalog.coachHistoryReset)
		#expect(!reset.opening.showsWelcome)
		_ = try await coach.sendAndSettle("And tomorrow?")
		#expect(await coach.currentSnapshot(.main)?.opening == .afterAutomaticReset(.daily))
		#expect(
			await self.coach(at: clock).currentSnapshot(.main)?.opening
				== .afterAutomaticReset(.daily))
		let marker =
			"Previous session archived at 1998-06-16T02:20:00.000Z. Briefly disclose this before answering."
		let chats = sent(.chatAttempt, by: transport).map { $0.messages.map(\.content) }
		try #require(chats.count == 3)
		#expect(chats.map { $0.filter { $0 == marker }.count } == [0, 1, 0])
		#expect(chats[1].suffix(1).first?.hasPrefix("What now?") == true)
		#expect(!chats[1].contains("How was my week?"))
	}

	@Test func idleResetFollowsTheStoredSetting() async throws {
		let clock = FixedClock(now: "1998-06-16T10:00:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = coach(at: clock)
		try await coach.setSession(SessionSettings.npmDefaults.replacing(.idleReset, with: "30"))
		answer("Two rides.", "Rest today.", "Easy spin.")
		_ = try await coach.sendAndSettle("How was my week?")
		clock.advance(by: 29 * 60)
		_ = try await coach.sendAndSettle("What now?")
		#expect(try await records(.synced([.windowStart])).isEmpty)
		clock.advance(by: 31 * 60)
		_ = try await coach.sendAndSettle("And tomorrow?")
		let boundaries = try await records(.synced([.windowStart])).map(\.body)
		let asked = try await records(.synced([.userMessage])).map(\.ulid)
		#expect(
			boundaries == [
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: asked[2], reason: .reset(.idle))))
			])
		#expect(await coach.currentSnapshot(.main)?.opening == .afterAutomaticReset(.idle))
		#expect(try await coach.history().map(\.reason) == [.closedAfterBreak])
		#expect(await coach.transcript(.main) == ["And tomorrow?", "Easy spin."])
	}

	@Test func aResetThatCannotBeSavedAnswersInTheSameConversation() async throws {
		let clock = FixedClock(now: "1998-06-15T20:00:00+02:00", timeZone: "Europe/Amsterdam")
		let log = FaultInjectingRecordLog(wrapping: store)
		let coach = coach(at: clock, over: log)
		answer("Two rides.", "Rest today.")
		_ = try await coach.sendAndSettle("How was my week?")
		log.failAppends(ofKind: SyncedKind.windowStart)
		clock.advance(by: 13 * 3_600)
		_ = try await coach.sendAndSettle("What now?")
		#expect(
			await coach.transcript(.main) == [
				"How was my week?", "Two rides.", "What now?", "Rest today.",
			])
		#expect(await coach.currentSnapshot(.main)?.opening == .continuing)
		#expect(
			coach.diagnostics.entries.contains {
				$0.event == .automaticResetUnsaved(.main, .rejectedBatch)
			})
	}
}
