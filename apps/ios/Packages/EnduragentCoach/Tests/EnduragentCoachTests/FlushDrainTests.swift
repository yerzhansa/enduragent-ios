import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushDrainTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	let saturdays: ScriptedEvent = .toolCall(
		name: "ledger_append",
		arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#)
	let schedule: ScriptedEvent = .toolCall(
		name: "memory_write",
		arguments: #"{"section":"schedule","content":"Group ride on Saturdays."}"#)

	func relaunched(over log: (any RecordLog)? = nil) async -> Coach {
		let coach = makeCoach(transport: transport, store: log ?? store, clock: clock)
		await coach.lifecycle(.becameActive)
		return coach
	}

	@discardableResult
	func seedJob(covering turn: SeededTurn, settled: Bool, process: ProcessID? = nil)
		async throws -> FlushJobID
	{
		let at = clock.now.addingTimeInterval(-5)
		let job = FlushJobID(ulid: ULID.generate(at: at))
		try await seed(
			store,
			[
				seededRecord(
					store, at: at, ulid: job.ulid,
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main,
								messageUlids: [turn.user, turn.reply], process: process))))
			])
		if settled {
			try await settle(job)
		}
		return job
	}

	func settle(_ job: FlushJobID) async throws {
		try await seed(
			store,
			[
				seededRecord(
					store, at: clock.now.addingTimeInterval(-4),
					ulid: ULID.generate(at: clock.now.addingTimeInterval(-4)),
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(chatId: .main, job: job, settlement: .nothingToSave))))
			])
	}

	func count(_ scope: RecordQuery.Scope) async throws -> Int {
		try await store.fetch(RecordQuery(scope: scope)).records.count
	}

	@Test func settledJobIsNotRerun() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		try await seedJob(covering: history[0], settled: true)
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		_ = try await relaunched().sendAndSettle("Anything else?")
		#expect(transport.requests.map(\.charge) == [.chatAttempt])
		#expect(try await count(.deviceLocal([.flushSettled])) == 1)
	}

	@Test(
		arguments: [
			ScriptedFailure.connection(.notConnectedToInternet), .connection(.timedOut),
			.http(status: 408), .http(status: 429), .http(status: 500), .http(status: 503),
			.http(status: 402),
		], [false, true])
	func aRelaunchDrainThatFailsTransientlyKeepsTheJobPending(
		failure: ScriptedFailure, partial: Bool
	) async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		let job = try await seedJob(
			covering: try #require(history.first), settled: false,
			process: ProcessID(ulid: fixedUlid(60)))
		transport.flushScript =
			(partial ? [saturdays, .finish(reason: .toolCalls)] : [])
			+ Array(repeating: .fail(failure), count: 4)
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		await coach.lifecycle(.becameActive)
		_ = try #require(await host.ended(0))
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		let expectedAttempts: Int
		switch failure.failure {
		case .accessExhausted: expectedAttempts = 1
		case .timeout: expectedAttempts = 2
		case .rateLimited: expectedAttempts = 2
		default: expectedAttempts = 3
		}
		let requestsBeforeRecovery = expectedAttempts + (partial ? 1 : 0)
		#expect(sent(.memoryFlush, by: transport).count == requestsBeforeRecovery)
		let original = try #require(sent(.memoryFlush, by: transport).first)
			.messages.dropFirst().prefix(2)

		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("Anything else?")
		_ = try #require(await host.ended(1))
		let flushes = sent(.memoryFlush, by: transport)
		#expect(flushes.count == requestsBeforeRecovery + 2)
		for request in flushes.suffix(2) {
			#expect(Array(request.messages.dropFirst().prefix(2)) == Array(original))
		}
		let events = try await store.fetch(RecordQuery(scope: .synced([.ledgerEvent]))).records
		#expect(events.count == 1)
		guard case .synced(.ledgerEvent(let event)) = try #require(events.first?.body) else {
			Issue.record("expected the recovered memory event")
			return
		}
		#expect(event.text == "Keep Saturdays free")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(jobs.map(\.id) == [job])
		#expect(jobs.map(\.saved) == [true])
		#expect(try await count(.deviceLocal([.flushSettled])) == 1)

		transport.script = [.text("Still noted."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("And later?")
		_ = try #require(await host.ended(2))
		#expect(sent(.memoryFlush, by: transport).count == flushes.count)
		#expect(try await count(.synced([.ledgerEvent])) == 1)
	}

	@Test(arguments: [
		ScriptedFailure.http(status: 400), .http(status: 401), .http(status: 403),
		.http(status: 404), .http(status: 422), .unknownFinish,
		.http(status: 400, body: "maximum context length is 8192 tokens"),
	])
	func aRelaunchDrainAbandonsATerminalFailure(failure: ScriptedFailure) async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		try await seedJob(
			covering: try #require(history.first), settled: false,
			process: ProcessID(ulid: fixedUlid(60)))
		transport.flushScript = [.fail(failure)]
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		await coach.lifecycle(.becameActive)
		_ = try #require(await host.ended(0))
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(jobs.map(\.abandoned) == [true])
		#expect(try await count(.deviceLocal([.flushSettled])) == 1)

		transport.script = [.text("Noted."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("Anything else?")
		_ = try #require(await host.ended(1))
		#expect(sent(.memoryFlush, by: transport).count == 1)
	}

	@Test func v1ConsumedMarkerStillSettlesAJob() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		let job = try await seedJob(covering: history[0], settled: false)
		try await seed(
			store,
			[
				seededRecord(
					store, at: clock.now.addingTimeInterval(-3),
					ulid: ULID.generate(at: clock.now.addingTimeInterval(-3)),
					body: .synced(
						.provenance(
							ProvenanceBody(
								key: MemoryFlushPolicy.consumedFlushKeyPrefix + job.ulid.rawValue,
								garmin: false, nonGarmin: false, unknown: false,
								contentSha256: "consumed"))))
			])
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		_ = try await relaunched().sendAndSettle("Anything else?")
		#expect(transport.requests.map(\.charge) == [.chatAttempt])
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		#expect(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).map(\.settled) == [
				true
			])
	}

	@Test func partialJobStaysPendingAndRerunDedupesLedgerEvents() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.flushScript = [
			saturdays, schedule, .finish(reason: .toolCalls), .fail(.http(status: 500)),
			.fail(.http(status: 500)), .fail(.http(status: 500)), saturdays,
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("Rest day?")
		try await waitForDiagnostic(in: coach) { event in
			if case .memoryFlushFailed(.main, _) = event { return true }
			return false
		}
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		#expect(try await count(.synced([.ledgerEvent])) == 1)
		#expect(try await count(.synced([.memorySection])) == 1)

		transport.script = [.text("Still noted."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("And Sunday?")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		#expect(try await count(.synced([.ledgerEvent])) == 1)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
	}

	@Test func drainAtLaunchStartsNoNewExtraction() async throws {
		let history = try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		try await seedJob(covering: history[0], settled: false)
		_ = await relaunched()
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(transport.requests.map(\.charge) == [.memoryFlush])
		let flushed = try #require(transport.requests.first).messages.map(\.unstampedContent)
		#expect(flushed.contains("Question 0"))
		#expect(!flushed.contains("Question 1"))
	}

	@Test func willTerminateStartsNoExtraction() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 2, tokens: 200)
		try await seedJob(covering: history[0], settled: false)
		try await seedJob(covering: history[1], settled: false)
		transport.flushScript = [.hang]
		let coach = await relaunched()
		try await waitUntil { sent(.memoryFlush, by: transport).count == 1 }
		await coach.lifecycle(.willTerminate)
		#expect(sent(.memoryFlush, by: transport).count == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
	}

	@Test func aKilledFlushIsDrainedAtTheNextLaunch() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .hang]
		let dying = FaultInjectingRecordLog(wrapping: store)
		let before = makeCoach(transport: transport, store: dying, clock: clock)
		let settled = try await before.sendAndSettle("Remember Saturdays", within: .seconds(5))
		#expect(replyText(settled) == "Noted.")
		try await waitForRecords(.synced([.ledgerEvent]), count: 1, in: store)
		try await before.dieWithoutWriting(to: dying)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)

		transport.flushScript = [saturdays, .finish(reason: .toolCalls), .finish(reason: .stop)]
		_ = await relaunched()
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		#expect(try await count(.synced([.ledgerEvent])) == 1)
	}

	@Test func aJobWrittenBeforeAKilledTurnIsDrainedAtTheNextLaunch() async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.hangUntilCancelled = true
		let dying = FaultInjectingRecordLog(wrapping: store)
		let before = makeCoach(transport: transport, store: dying, clock: clock)
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		try await waitForRecords(.deviceLocal([.flushPending]), count: 1, in: store)
		await before.waitUntilProcessing(turn)
		try await before.dieWithoutWriting(to: dying)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)

		transport.hangUntilCancelled = false
		let after = await relaunched()
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		guard case .interrupted(let interrupted)? = await after.state(of: turn) else {
			Issue.record("expected the killed turn to be interrupted")
			return
		}
		#expect(interrupted.cause == .processEnded)
	}

	private func waitForDiagnostic(
		in coach: Coach, within limit: Duration = .seconds(5),
		_ matches: (DiagnosticsEvent) -> Bool
	) async throws {
		try await waitUntil(within: limit) {
			coach.diagnostics.entries.map(\.event).contains(where: matches)
		}
	}
}
