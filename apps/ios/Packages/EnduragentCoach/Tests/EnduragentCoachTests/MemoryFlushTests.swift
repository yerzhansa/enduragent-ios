import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct MemoryFlushTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	var memory: Memory {
		Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
	}

	var conversation: [ChatMessage] {
		[
			ChatMessage(
				author: .athlete(sent: clock.now.addingTimeInterval(-120)),
				text: "Remember that I ride with a group on Saturdays"),
			ChatMessage(author: .coach, text: "Noted."),
		]
	}

	func job() -> FlushJob {
		FlushJob(id: FlushJobID(ulid: fixedUlid(40)), messages: [fixedUlid(41)], settled: false)
	}

	func run(
		_ job: FlushJob, messages: [ChatMessage]? = nil, scope: TurnScope? = nil
	) async throws -> FlushOutcome {
		try await memory.runFlush(
			messages: messages ?? conversation, access: testAccess, transport: transport,
			diagnostics: DiagnosticsLog(clock: clock), ladder: .npm,
			stamp: testStamp(operation: .memoryFlush(job.id)), scope: scope)
	}

	@Test(arguments: [401, 429])
	func flushHonorsProviderFailures(status: Int) async throws {
		let held = HeldClock()
		try await seedHistory(store, clock: held, turns: 1, tokens: 200)
		transport.flushScript = [
			.fail(.http(status: status, headers: ["Retry-After": "7"])),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: held)
		let reset = Task { await coach.startNewConversation(in: .main) }
		defer { reset.cancel() }
		if status == 429 {
			try await held.waitUntilHeld(.seconds(7))
			#expect(sent(.memoryFlush, by: transport).count == 1)
			held.release(.seconds(7))
			#expect(await reset.value == .started(memory: .saved))
			#expect(sent(.memoryFlush, by: transport).count == 2)
		} else {
			#expect(await reset.value == .started(memory: .notSaved))
			#expect(sent(.memoryFlush, by: transport).count == 1)
			#expect(held.held.isEmpty)
		}
	}

	@Test func flushCannotWriteAnUnlistedSection() async throws {
		try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		transport.flushScript = [
			.toolCall(
				name: "memory_write",
				arguments: #"{"section":"unlisted","content":"Must not be stored."}"#),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let written = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		#expect(written.isEmpty)
		let followUp = try #require(sent(.memoryFlush, by: transport).last)
		let result = try #require(followUp.messages.last(where: { $0.role == .tool }))
		#expect(result.content.contains("unknown_section"))
	}

	@Test(arguments: [FinishReason.error, .contentFilter])
	func flushReportsFailedGeneration(reason: FinishReason) async throws {
		try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		transport.flushScript = [.finish(reason: reason)]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .notSaved))
		#expect(sent(.memoryFlush, by: transport).count == 1)
	}

	@Test func flushUsesOnlyMemoryWriteAndLedgerAppend() async throws {
		transport.flushScript = [
			.toolCall(
				name: "ledger_append",
				arguments:
					#"{"kind":"decision","date":"1998-06-13","text":"Rides with a group on Saturdays"}"#
			),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		#expect(try await run(job()) == .saved(sections: 0, events: 1))
		#expect(transport.requests.count == 2)
		#expect(transport.requests[0].tools.map(\.name) == [.memoryWrite, .ledgerAppend])
		let hits = try await memory.query(
			from: "1998-06-13", to: "1998-06-13", contains: "Saturdays")
		#expect(hits.count == 1)
	}

	@Test func everyWriteCarriesTheJobsOperation() async throws {
		transport.flushScript = [
			.toolCall(
				name: "memory_write",
				arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let job = job()
		#expect(try await run(job) == .saved(sections: 1, events: 0))
		let written = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		guard case .operation(.memoryFlush(let stamped), _)? = written.first?.cause else {
			Issue.record("expected a memory flush stamp, got \(String(describing: written.first))")
			return
		}
		#expect(stamped == job.id)
	}

	@Test func noMessagesIsNothingToSaveWithoutARequest() async throws {
		#expect(try await run(job(), messages: []) == .nothingToSave)
		#expect(transport.requests.isEmpty)
	}

	@Test func aFailedGenerateUsesTheLadderThenReportsTheWritesItMade() async throws {
		transport.flushScript = [
			.toolCall(
				name: "memory_write",
				arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#),
			.finish(reason: .toolCalls),
			.fail(.http(status: 500)),
			.fail(.http(status: 500)),
			.fail(.http(status: 500)),
		]
		#expect(
			try await run(job())
				== .partial(sections: 1, events: 0, failure: .model(.providerDown(.outage))))
		#expect(transport.requests.count == 4)
		transport.flushScript = [.fail(.http(status: 500)), .text("ok"), .finish(reason: .stop)]
		#expect(try await run(job()) == .nothingToSave)
		transport.flushScript = Array(repeating: .fail(.http(status: 500)), count: 3)
		#expect(try await run(job()) == .failed(.model(.providerDown(.outage))))
	}

	@Test func aFlushRetryKeepsToolResultsWithoutRepeatingWrites() async throws {
		let append = ScriptedEvent.toolCall(
			name: "ledger_append",
			arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#)
		transport.flushScript = [
			.toolCall(
				name: "memory_write",
				arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#),
			append, .finish(reason: .toolCalls), .fail(.http(status: 500)),
			append, .finish(reason: .toolCalls), .finish(reason: .stop),
		]
		#expect(try await run(job()) == .saved(sections: 1, events: 1))
		#expect(transport.requests.count == 4)
		let failed = transport.requests[1].messages
		let retried = transport.requests[2].messages
		#expect(retried == failed)
		#expect(retried.filter { $0.role == .tool }.count == 2)
		let sections = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		let events = try await store.fetch(RecordQuery(scope: .synced([.ledgerEvent]))).records
		#expect(sections.count == 1)
		#expect(events.count == 1)
		let repeated = try #require(transport.requests.last?.messages.last)
		#expect(repeated.content.contains(#""duplicate":true"#))
	}

	@Test func missingFlushContentGetsTheFlushArgumentMessage() async throws {
		try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		transport.flushScript = [
			.toolCall(name: "memory_write", arguments: #"{"section":"schedule"}"#),
			.finish(reason: .toolCalls), .finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let result = try #require(sent(.memoryFlush, by: transport).last?.messages.last)
		#expect(result.content.contains("requires a section and content"))
		#expect(!result.content.contains("type='"))
		let sections = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		#expect(sections.isEmpty)
	}

	@Test func flushCapsAtFiveSteps() async throws {
		var script: [ScriptedEvent] = []
		for _ in 0..<6 {
			script.append(
				.toolCall(
					name: "ledger_append",
					arguments: #"{"kind":"decision","date":"1998-06-13","text":"Hold volume"}"#
				)
			)
			script.append(.finish(reason: .toolCalls))
		}
		script.append(.finish(reason: .stop))
		transport.flushScript = script
		#expect(try await run(job()) == .saved(sections: 0, events: 1))
		#expect(transport.requests.count == MemoryFlushPolicy.maxSteps)
		#expect(
			transport.requests.allSatisfy { $0.tools.map(\.name) == [.memoryWrite, .ledgerAppend] })
	}

	@Test func aMultiStepFlushChargesTheTurnOneCall() async throws {
		transport.flushScript = [
			.toolCall(
				name: "ledger_append",
				arguments: #"{"kind":"decision","date":"1998-06-13","text":"Hold volume"}"#),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let roomForOne = TurnScope(
			stamp: testStamp(), policy: budget(calls: 1), uptime: clock.uptime)
		#expect(try await run(job(), scope: roomForOne) == .saved(sections: 0, events: 1))
		#expect(transport.requests.count == 2)
		await #expect(throws: TurnBudgetExceeded(kind: .generateCalls)) {
			try await roomForOne.chargeCall()
		}
	}

	@Test func aSpentTurnBudgetStopsTheFlushBeforeAnyRequest() async throws {
		transport.flushScript = [.text("never sent"), .finish(reason: .stop)]
		let spent = TurnScope(stamp: testStamp(), policy: budget(calls: 1), uptime: clock.uptime)
		try await spent.chargeCall()
		#expect(
			try await run(job(), scope: spent)
				== .failed(.model(.budgetExhausted(.generateCalls))))
		#expect(transport.requests.isEmpty)
	}

	@Test func softThresholdJobIsWrittenBeforeTheReplyAndDrainedAfterIt() async throws {
		let history = try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		transport.flushScript = [
			.toolCall(
				name: "ledger_append",
				arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#
			),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let settled = try await coach.sendAndSettle("Remember Saturdays")
		#expect(replyText(settled) == "Noted.")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		let pending = try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending])))
			.records
		guard case .deviceLocal(.flushPending(let body))? = pending.first?.body else {
			Issue.record("expected one soft job, got \(pending)")
			return
		}
		#expect(pending.count == 1)
		#expect(body.messageUlids == history.flatMap { [$0.user, $0.reply] })
		#expect(transport.requests.map(\.charge) == [.chatAttempt, .memoryFlush, .memoryFlush])
		let hits = try await coach.memory.query(
			from: "1998-06-13", to: "1998-06-13", contains: "Saturdays")
		#expect(hits.count == 1)
	}

	@Test func blankFlushArgumentsReturnTheMissingSectionToTheModel() async throws {
		_ = try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		transport.flushScript = [
			.toolCall(name: "memory_write", arguments: ""),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let settled = try await coach.sendAndSettle("Remember Saturdays")
		#expect(replyText(settled) == "Noted.")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		let flushRequests = transport.requests.filter { $0.charge == .memoryFlush }
		#expect(flushRequests.count == 2)
		let followUp = try #require(flushRequests.last)
		let result = try #require(followUp.messages.last(where: { $0.role == .tool }))
		#expect(result.content.contains(#""error":"section_required""#))
	}

	private func budget(calls: Int) -> TurnBudgetPolicy {
		TurnBudgetPolicy(
			maxGenerateAttempts: 4, maxGenerateCalls: calls, wallClock: .seconds(600),
			maxStepsPerInvocation: 10, perCallDeadline: .seconds(600))
	}
}
