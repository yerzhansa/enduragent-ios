import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct FlushJobRefreshTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let store = InMemoryRecordLog()

	@Test func aFailedJobRefreshDoesNotRepeatASavedFlush() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		let faults = FaultInjectingRecordLog(wrapping: store)
		let transport = FakeModelTransport { request in
			if request.purpose == .flush {
				guard request.step == 0 else { return ScriptedReply([.finish(reason: .stop)]) }
				return ScriptedReply([
					.toolCall(
						name: "memory_write",
						arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#),
					.toolCall(
						name: "ledger_append",
						arguments:
							#"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#
					),
					.finish(reason: .toolCalls),
				])
			}
			if request.text == "After the save" {
				faults.failNextFetch(in: ConversationFold.flushScope)
			}
			return ScriptedReply([.text("Noted."), .finish(reason: .stop)])
		}
		let host = ImmediateExecutionHost()
		let coach = await makeCoach(transport: transport, store: faults, clock: clock, host: host)
		#expect(replyText(try await coach.sendAndSettle("Save the history")) == "Noted.")
		_ = try #require(await host.ended(0))
		try #require(sent(.memoryFlush, by: transport).count == 2)
		let savedJobs = try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending])))
		try #require(savedJobs.records.count == 1)

		#expect(replyText(try await coach.sendAndSettle("After the save")) == "Noted.")
		_ = try #require(await host.ended(1))
		#expect(
			coach.diagnostics.entries.filter {
				if case .memoryFlushFailed = $0.event { return true }
				return false
			}.count == 1)

		#expect(replyText(try await coach.sendAndSettle("After the failed read")) == "Noted.")
		_ = try #require(await host.ended(2))
		#expect(sent(.memoryFlush, by: transport).count == 2)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending]))) == savedJobs)
		let sections = try await store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
		#expect(sections.count == 1)
		#expect(
			try await coach.memory.fullContext(for: testConnection.account).contains(
				"Group ride on Saturdays."))
		let notes = try await coach.memory.query(
			from: "1998-06-13", to: "1998-06-13", contains: "Keep Saturdays free",
			for: testConnection.account)
		#expect(notes.count == 1)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.ledgerEvent]))).records.count == 1)
		await coach.lifecycle(.willTerminate)
	}

	@Test func aSuccessfulEmptyJobReadClearsSavedCoverage() async throws {
		let diagnostics = DiagnosticsLog(clock: clock)
		let ledger = Ledger(log: store, clock: clock, diagnostics: diagnostics)
		let pending = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: [], process: ProcessID(ulid: fixedUlid(60))))
			], stamp: testStamp())
		let job = FlushJobID(ulid: try #require(pending.first?.ulid))
		_ = try await ledger.commit(
			local: [
				.flushSettled(FlushSettledBody(chatId: .main, job: job, settlement: .nothingToSave))
			],
			stamp: testStamp())
		let records = ChatRecords(
			chat: .main, ledger: ledger, clock: clock,
			reviews: SingleProposalReviews(
				ledger: ledger, clock: clock, diagnostics: diagnostics,
				training: { _ in .unconnected }))
		try await records.refresh()
		try #require(records.jobs.map(\.id) == [job])
		let empty = Ledger(
			log: InMemoryRecordLog(deviceId: store.deviceId), clock: clock, diagnostics: diagnostics
		)
		let flushes = FlushWork(
			chat: .main, process: ProcessID(ulid: fixedUlid(61)), ledger: empty,
			memory: Memory(ledger: empty, clock: clock), transport: FakeModelTransport(),
			clock: clock, diagnostics: diagnostics, ladder: .npm)
		#expect(await records.refreshJobs(from: flushes).isEmpty)
		#expect(records.jobs.isEmpty)
	}

	@Test func aFailedResetJobReadKeepsSavedCoverage() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 3, tokens: 400)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let pending = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(
						chatId: .main, messageUlids: history.flatMap { [$0.user, $0.reply] },
						process: ProcessID(ulid: fixedUlid(60))))
			], stamp: testStamp())
		let job = FlushJobID(ulid: try #require(pending.first?.ulid))
		_ = try await ledger.commit(
			local: [
				.flushSettled(FlushSettledBody(chatId: .main, job: job, settlement: .nothingToSave))
			],
			stamp: testStamp())
		let faults = FaultInjectingRecordLog(wrapping: store)
		let transport = FakeModelTransport { _ in ScriptedReply([.finish(reason: .stop)]) }
		let coach = await makeCoach(transport: transport, store: faults, clock: clock)
		_ = try #require(await coach.currentSnapshot(.main))
		faults.failNextFetch(in: ConversationFold.flushScope)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		#expect(sent(.memoryFlush, by: transport).isEmpty)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending]))).records
				== pending)
		await coach.lifecycle(.willTerminate)
	}
}
