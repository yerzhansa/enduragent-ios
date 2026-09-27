import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushOrderTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func aJobIsDoneWhenASettledJobCoversAllItsMessages() {
		let jobs = [
			job(8, messages: [1]), job(9, messages: []), job(10, messages: [1, 2]),
			job(11, messages: [1, 2, 3], settled: true), job(12, messages: [4]),
		]
		let local = jobs.enumerated().flatMap { records(for: $1, at: $0) }
		let folded = ConversationFold.flushJobs(
			chat: .main, local: local, markers: [], device: store.deviceId)
		#expect(folded.map(\.settled) == [true, true, true, true, false])
		#expect(!job(13, messages: [1, 2]).covers(job(14, messages: [1])))
		#expect(!job(15, messages: [1]).covers(job(14, messages: [1, 2])))
	}

	@Test func aJobKeepsItsProcessAndAnAbandonedSettlementRoundTrips() throws {
		let process = ProcessID(ulid: fixedUlid(60))
		let pending = FlushPendingBody(
			chatId: .main, trigger: .trim, messageUlids: [fixedUlid(1)], process: process)
		let abandoned = FlushSettledBody(
			chatId: .main, job: FlushJobID(ulid: fixedUlid(2)), settlement: .abandoned)
		for body in [
			RecordBody.deviceLocal(.flushPending(pending)), .deviceLocal(.flushSettled(abandoned)),
		] {
			let encoded = try RecordCodec.encode(body)
			#expect(
				RecordCodec.decode(
					kind: body.kind, version: encoded.version, data: encoded.data,
					civilDate: "1998-06-13", ulid: fixedUlid(3).rawValue) == .success(body))
		}
		let older = Data(
			#"{"chatId":"main","trigger":"trim","messageUlids":["\#(fixedUlid(1).rawValue)"]}"#.utf8
		)
		var withoutProcess = pending
		withoutProcess.process = nil
		#expect(
			RecordCodec.decode(
				kind: "flushPending", version: 2, data: older, civilDate: "1998-06-13",
				ulid: fixedUlid(4).rawValue)
				== .success(.deviceLocal(.flushPending(withoutProcess))))
	}

	@Test func onlyTheNewestOfNestedPendingJobsIsOutstanding() {
		let older = job(10, messages: [1, 2])
		let newer = job(11, messages: [1, 2, 3])
		let separate = job(12, messages: [4])
		#expect(
			FlushJob.outstanding([older, newer, separate]).map(\.id) == [newer.id, separate.id])
	}

	@Test func anOlderJobNeverRunsAfterANewerWindowThatCoversIt() async throws {
		let budget = historyBudget(clock: clock)
		let history = try await seedHistory(store, clock: clock, turns: 3, tokens: budget * 9 / 10)
		transport.flushScript =
			[.fail(.http(status: 500)), .fail(.http(status: 500))]
			+ memoryWrite("Sundays now.") + memoryWrite("Saturdays.")
		transport.summaryScript = [.text("Earlier."), .finish(reason: .stop)]
		let longReply = "Long " + String(repeating: "r", count: budget / 2)
		transport.script = [
			.text(longReply), .finish(reason: .stop), .text("Noted."), .finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Rest day?")
		try await waitUntil { sent(.memoryFlush, by: transport).count == 2 }
		_ = try await coach.sendAndSettle("And Sunday?")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		try await Task.sleep(for: .milliseconds(200))
		let flushes = sent(.memoryFlush, by: transport)
		#expect(flushes.count == 4)
		let window = flushes[2].messages.map(\.content)
		#expect(window.contains { $0.hasPrefix("Question 0") })
		#expect(window.contains { $0 == "Rest day?" })
		let memory = Memory(ledger: ledger(), clock: clock)
		let context = try await memory.fullContext()
		#expect(context.contains("Sundays now."))
		#expect(!context.contains("Saturdays."))
		let jobs = try await ledger().flushJobs(in: .main)
		#expect(jobs.map(\.trigger) == [.softThreshold, .trim])
		#expect(jobs.map(\.settled) == [true, true])
		#expect(jobs.first?.messages == history.flatMap { [$0.user, $0.reply] })
	}

	@Test func aFailingJobRetriesInItsProcessAndIsAbandonedAfterTheNextLaunchDrain() async throws {
		let history = try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.flushScript = Array(repeating: .fail(.http(status: 400)), count: 12)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		for index in 0..<3 {
			transport.script = [.text("Reply \(index)."), .finish(reason: .stop)]
			_ = try await coach.sendAndSettle("Ask \(index)?")
			try await waitUntil { sent(.memoryFlush, by: transport).count == 2 * (index + 1) }
		}
		#expect(try await count(.flushPending) == 1)
		#expect(try await count(.flushSettled) == 0)

		let relaunched = makeCoach(transport: transport, store: store, clock: clock)
		await relaunched.lifecycle(.becameActive)
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		#expect(sent(.memoryFlush, by: transport).count == 8)
		#expect(try await settlements() == [.abandoned])

		transport.script = [.text("Reply 3."), .finish(reason: .stop)]
		_ = try await relaunched.sendAndSettle("Ask 3?")
		try await waitUntil { sent(.memoryFlush, by: transport).count == 10 }
		let jobs = try await ledger().flushJobs(in: .main)
		#expect(jobs.count == 2)
		let seeded = Set(history.flatMap { [$0.user, $0.reply] })
		let fresh = try #require(jobs.last)
		#expect(fresh.messages.allSatisfy { !seeded.contains($0) })
		#expect(jobs.map(\.settled) == [true, false])
	}

	private func job(_ offset: Int, messages: [Int], settled: Bool = false) -> FlushJob {
		FlushJob(
			id: FlushJobID(ulid: fixedUlid(offset)), trigger: .softThreshold,
			messages: messages.map(fixedUlid), settled: settled)
	}

	private func records(for job: FlushJob, at index: Int) -> [AthleteRecord] {
		let at = clock.now.addingTimeInterval(TimeInterval(-100 + index))
		var records = [
			seededRecord(
				store, at: at, ulid: job.id.ulid,
				body: .deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, trigger: job.trigger, messageUlids: job.messages))))
		]
		if job.settled {
			records.append(
				seededRecord(
					store, at: at, ulid: fixedUlid(200),
					body: .deviceLocal(
						.flushSettled(
							FlushSettledBody(
								chatId: .main, job: job.id, settlement: .nothingToSave)))))
		}
		return records
	}

	private func memoryWrite(_ content: String) -> [ScriptedEvent] {
		[
			.toolCall(
				name: ToolName.memoryWrite.rawValue,
				arguments: #"{"section":"schedule","content":"\#(content)"}"#),
			.finish(reason: .toolCalls), .finish(reason: .stop),
		]
	}

	private func ledger() -> Ledger {
		Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
	}

	private func count(_ kind: DeviceLocalKind) async throws -> Int {
		try await store.fetch(RecordQuery(scope: .deviceLocal([kind]))).records.count
	}

	private func settlements() async throws -> [FlushSettlement] {
		try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records
			.compactMap { record in
				guard case .deviceLocal(.flushSettled(let body)) = record.body else { return nil }
				return body.settlement
			}
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(5)
		while !condition(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(condition())
	}
}
