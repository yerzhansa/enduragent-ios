import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ResetTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	let schedule: ScriptedEvent = .toolCall(
		name: "memory_write",
		arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#)

	func coach(over log: (any RecordLog)? = nil) -> Coach {
		makeCoach(transport: transport, store: log ?? store, clock: clock)
	}

	func answer(_ replies: String...) {
		transport.script = replies.flatMap { [ScriptedEvent.text($0), .finish(reason: .stop)] }
	}

	func written(_ kinds: Set<String>) async throws -> [String] {
		let synced = try await store.fetch(RecordQuery(scope: .everySynced)).records
		let local = try await store.fetch(RecordQuery(scope: .everyDeviceLocal)).records
		return (synced + local).sorted { $0.hlc < $1.hlc }.map(\.body.kind)
			.filter { kinds.contains($0) }
	}

	func count(_ scope: RecordQuery.Scope) async throws -> Int {
		try await store.fetch(RecordQuery(scope: scope)).records.count
	}

	@Test func resetFlushesThenCommitsBoundaryThenSettlesFlush() async throws {
		let coach = coach()
		answer("Two rides.")
		_ = try await coach.sendAndSettle("How was my week?")
		transport.flushScript = [schedule, .finish(reason: .toolCalls)]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(
			try await written(["flushPending", "memorySection", "windowStart", "flushSettled"])
				== ["flushPending", "memorySection", "windowStart", "flushSettled"])
		let flushed = try #require(sent(.memoryFlush, by: transport).first)
		#expect(flushed.messages.contains { $0.unstampedContent == "How was my week?" })
		#expect(flushed.messages.contains { $0.unstampedContent == "Two rides." })
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .afterNewConversation(memorySaved: true))
		let reopened = try #require(await self.coach().currentSnapshot(.main))
		#expect(reopened.turns.isEmpty)
		#expect(reopened.opening == .afterNewConversation(memorySaved: true))
	}

	@Test func deathBeforeBoundaryLeavesConversationAndJobPending() async throws {
		let log = FaultInjectingRecordLog(wrapping: store)
		let coach = coach(over: log)
		answer("Two rides.")
		_ = try await coach.sendAndSettle("How was my week?")
		transport.flushScript = [schedule, .finish(reason: .toolCalls)]
		try log.failAppends(ofKind: "windowStart")
		#expect(await coach.startNewConversation(in: .main) == .notStarted(.local(.recordStorage)))
		#expect(await coach.transcript(.main) == ["How was my week?", "Two rides."])
		#expect(await coach.currentSnapshot(.main)?.opening == .continuing)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		#expect(try await count(.synced([.windowStart])) == 0)
		#expect(try await coach.history().isEmpty)
	}

	@Test func resetLeavesWorkoutReviewUntouched() async throws {
		let nonce = Nonce()
		let proposal = sampleProposal(
			chatId: .main, nonce: nonce, expiresAt: clock.now.addingTimeInterval(300))
		try await seed(
			store,
			[
				seededRecord(
					store, at: clock.now.addingTimeInterval(-10),
					ulid: ULID.generate(at: clock.now.addingTimeInterval(-10)),
					body: .deviceLocal(.pendingProposal(proposal)))
			])
		let coach = coach()
		answer("Here is Thursday.")
		_ = try await coach.sendAndSettle("Plan Thursday")
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(await coach.currentSnapshot(.main)?.review?.ref == review.ref)
		#expect(try await count(.deviceLocal([.proposalCleared])) == 0)
		#expect(await self.coach().currentSnapshot(.main)?.review?.ref.set == review.ref.set)
	}

	@Test func resetWithPartialFlushReportsPartiallySaved() async throws {
		let coach = coach()
		answer("Two rides.")
		_ = try await coach.sendAndSettle("How was my week?")
		transport.flushScript =
			[schedule, .finish(reason: .toolCalls)]
			+ Array(repeating: .fail(.http(status: 500)), count: 4)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .partiallySaved))
		#expect(try await count(.synced([.memorySection])) == 1)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .afterNewConversation(memorySaved: false))
		#expect(snapshot.opening.notice == Catalog.chatNoticeNewConversationMemoryWarning)
	}

	@Test func theSnapshotShowsTheMemoryWarningWhenNewConversationReturns() async throws {
		let log = SlowScopeLog(
			inner: store, scope: ConversationFold.flushScope, delay: .milliseconds(300))
		let coach = coach(over: log)
		answer("Two rides.")
		_ = try await coach.sendAndSettle("How was my week?")
		transport.flushScript = Array(repeating: .fail(.http(status: 500)), count: 3)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .notSaved))
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.opening == .afterNewConversation(memorySaved: false))
	}

	@Test func anAbandonedResetFlushKeepsTheMemoryWarningAfterRelaunch() async throws {
		let coach = coach()
		answer("Two rides.")
		_ = try await coach.sendAndSettle("How was my week?")
		transport.flushScript = Array(repeating: .fail(.http(status: 400)), count: 8)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .notSaved))
		transport.flushScript = Array(repeating: .fail(.http(status: 400)), count: 8)
		let reopened = self.coach()
		await reopened.lifecycle(.becameActive)
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		let snapshot = try #require(await reopened.currentSnapshot(.main))
		#expect(snapshot.opening == .afterNewConversation(memorySaved: false))
	}

	@Test func aTransientResetFlushRecoversTheMemorySavedOpeningAfterRelaunch() async throws {
		let coach = coach()
		answer("Two rides.")
		_ = try await coach.sendAndSettle("How was my week?")
		let offline = ScriptedEvent.fail(.connection(.notConnectedToInternet))
		transport.flushScript = [offline, offline, offline]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .notSaved))
		#expect(
			await coach.currentSnapshot(.main)?.opening == .afterNewConversation(memorySaved: false)
		)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		let original = try #require(sent(.memoryFlush, by: transport).first).messages

		transport.flushScript = [offline, offline, offline]
		let offlineHost = ImmediateExecutionHost()
		let reopened = makeCoach(
			transport: transport, store: store, clock: clock, host: offlineHost)
		await reopened.lifecycle(.becameActive)
		_ = try #require(await offlineHost.ended(0))
		#expect(
			await reopened.currentSnapshot(.main)?.opening
				== .afterNewConversation(memorySaved: false))
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		#expect(sent(.memoryFlush, by: transport).count == 6)

		transport.flushScript = [schedule, .finish(reason: .toolCalls), .finish(reason: .stop)]
		let healthyHost = ImmediateExecutionHost()
		let recovered = makeCoach(
			transport: transport, store: store, clock: clock, host: healthyHost)
		await recovered.lifecycle(.becameActive)
		_ = try #require(await healthyHost.ended(0))
		let snapshot = try #require(await recovered.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .afterNewConversation(memorySaved: true))
		#expect(try await count(.synced([.memorySection])) == 1)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 1)
		let flushes = sent(.memoryFlush, by: transport)
		#expect(flushes.count == 8)
		#expect(flushes.dropFirst(6).first?.messages == original)
		#expect(
			await self.coach().currentSnapshot(.main)?.opening
				== .afterNewConversation(memorySaved: true))
	}

	@Test func theResetWindowStartsWithTheOutstandingJobsRows() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 2, tokens: 400)
		let at = clock.now.addingTimeInterval(-5)
		try await seed(
			store,
			[
				seededRecord(
					store, at: at, ulid: ULID.generate(at: at),
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [history[0].user, history[0].reply],
								process: ProcessID(ulid: fixedUlid(70))))))
			])
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let flushes = FlushWork(
			chat: .main, process: ProcessID(ulid: fixedUlid(71)), ledger: ledger,
			memory: Memory(ledger: ledger, clock: clock), transport: transport, clock: clock,
			diagnostics: DiagnosticsLog(clock: clock), ladder: .npm)
		transport.flushScript = [schedule, .finish(reason: .toolCalls)]
		let reset = ResetID(ulid: await ledger.nextULID())
		let result = await ConversationReset(
			chat: .main, ledger: ledger, flushes: flushes, clock: clock
		).run(reset, archiving: try await ledger.conversation(.main), access: { testAccess })
		#expect(result.outcome == .started(memory: .saved))
		let flushed = try #require(sent(.memoryFlush, by: transport).first)
		let window = flushed.messages.map(\.unstampedContent)
		#expect(window.contains("Question 0"))
		#expect(window.contains("Question 1"))
		#expect(
			FlushJob.outstanding(
				await flushes.jobs(in: try await ledger.conversation(.main)),
				in: try await ledger.conversation(.main)
			)
			.isEmpty)
	}

	@Test func resetQueuesBehindRunningTurn() async throws {
		let held = HeldAppendLog(inner: store, holding: "turnSettled", occurrence: 1)
		let coach = coach(over: held)
		answer("Two rides.")
		let turn = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		let resetting = Task { await coach.startNewConversation(in: .main) }
		try await Task.sleep(for: .milliseconds(300))
		#expect(sent(.memoryFlush, by: transport).isEmpty)
		#expect(try await count(.synced([.windowStart])) == 0)
		held.release()
		#expect(await resetting.value == .started(memory: .saved))
		#expect(
			try await written(["turnSettled", "windowStart"]) == ["turnSettled", "windowStart"])
		let flushed = try #require(sent(.memoryFlush, by: transport).first)
		#expect(flushed.messages.contains { $0.unstampedContent == "Two rides." })
		let archivedRef = try #require(try await coach.history().first?.id)
		let archived = try #require(try await coach.archivedConversation(archivedRef))
		#expect(archived.turns.map(\.id) == [turn])
		#expect(archived.reason == .newConversation)
		#expect(replyText(try #require(archived.turns.first?.state)) == "Two rides.")
	}

	@Test func messageSentWhileResetWaitsOpensTheNewConversation() async throws {
		let held = HeldAppendLog(inner: store, holding: "turnSettled", occurrence: 1)
		let coach = coach(over: held)
		answer("Two rides.", "Noted.")
		let first = try #require(
			try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		let resetting = Task { await coach.startNewConversation(in: .main) }
		try await Task.sleep(for: .milliseconds(500))
		let second = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		held.release()
		#expect(await resetting.value == .started(memory: .saved))
		#expect(
			replyText(try #require(await coach.settledState(of: second, in: .main))) == "Noted.")
		#expect(await coach.transcript(.main) == ["Remember Saturdays", "Noted."])
		let history = try await coach.history()
		#expect(history.count == 1)
		let ref = try #require(history.first?.id)
		#expect(try await coach.archivedConversation(ref)?.turns.map(\.id) == [first])
		#expect(await self.coach().transcript(.main) == ["Remember Saturdays", "Noted."])
	}
}
