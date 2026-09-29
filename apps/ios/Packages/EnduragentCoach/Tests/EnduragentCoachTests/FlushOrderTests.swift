import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushOrderTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test func aJobIsDoneWhenASettledJobCoversAllItsMessages() {
		let jobs = [
			job(8, messages: [1]), job(9, messages: [1, 2]), job(10, messages: [1, 2]),
			job(11, messages: [1, 2, 3], settled: true), job(12, messages: [4]),
		]
		let conversation = coverageConversation()
		let local = jobs.enumerated().flatMap { records(for: $1, at: $0) }
		let folded = FlushJob.settling(
			ConversationFold.flushJobs(
				chat: .main, local: local, markers: [], device: store.deviceId),
			resolved: FlushRows(jobs, in: conversation).byJob)
		#expect(folded.map(\.settled) == [true, true, true, true, false])
		let older = job(13, messages: [1, 2])
		let newer = job(14, messages: [1])
		let rows = FlushRows([older, newer], in: conversation)
		#expect(!older.covers(newer, resolved: rows.byJob))
		#expect(!newer.covers(older, resolved: rows.byJob))
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
			FlushJob.outstanding([older, newer, separate], in: coverageConversation()).map(\.id)
				== [newer.id, separate.id])
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
		let window = flushes[2].messages.map(\.unstampedContent)
		#expect(window.contains { $0.hasPrefix("Question 0") })
		#expect(window.contains { $0 == "Rest day?" })
		let memory = Memory(ledger: ledger(), clock: clock)
		let context = try await memory.fullContext()
		#expect(context.contains("Sundays now."))
		#expect(!context.contains("Saturdays."))
		let jobs = try await ledger().flushJobs(in: try await ledger().conversation(.main))
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
		let jobs = try await ledger().flushJobs(in: try await ledger().conversation(.main))
		#expect(jobs.count == 2)
		let seeded = Set(history.flatMap { [$0.user, $0.reply] })
		let fresh = try #require(jobs.last)
		#expect(fresh.messages.allSatisfy { !seeded.contains($0) })
		#expect(jobs.map(\.settled) == [true, false])
	}

	@Test func aTrimNeverSplitsATurn() async throws {
		let budget = historyBudget(clock: clock)
		var seeded: [SeededTurn] = []
		for index in 0..<3 {
			let asked = clock.now.addingTimeInterval(TimeInterval(-60 * (3 - index)))
			let user = ULID.generate(at: asked)
			let reply = ULID.generate(at: asked.addingTimeInterval(1))
			let turn = TurnID(ulid: user)
			let question = "Question \(index) " + String(repeating: "q", count: budget / 3)
			let answer = "Answer \(index) " + String(repeating: "w", count: budget * 5 / 6)
			try await seed(
				store,
				[
					seededRecord(
						store, at: asked, ulid: user,
						body: .synced(sampleUser(chatId: .main, text: question, turn: turn))),
					seededRecord(
						store, at: asked.addingTimeInterval(1), ulid: reply,
						body: .synced(sampleReply(chatId: .main, turn: turn, text: answer))),
				])
			seeded.append(SeededTurn(turn: turn, user: user, reply: reply))
		}
		transport.summaryScript = [
			.text("Summary one."), .finish(reason: .stop), .text("Summary two."),
			.finish(reason: .stop),
		]
		transport.script = [
			.text("Ok."), .finish(reason: .stop), .text("Ok again."), .finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Short?")
		let windows = try await store.fetch(
			RecordQuery(scope: .synced([.windowStart], includeLegacy: []))
		).records.compactMap { record -> ULID? in
			guard case .synced(.windowStart(let body)) = record.body else { return nil }
			return body.firstIncludedUlid
		}
		#expect(windows.count == 1)
		let firstIncluded = try #require(windows.first)
		#expect(seeded.map(\.user).contains(firstIncluded))
		_ = try await coach.sendAndSettle("Short again?")
		let lastChat = try #require(sent(.chatAttempt, by: transport).last)
		#expect(!lastChat.messages.contains { $0.unstampedContent.hasPrefix("Question 0") })
		#expect(sent(.droppedSummary, by: transport).count == 1)
	}

	@Test func aTrimThatWouldKeepOnlyAReplyStartsTheWindowAtTheRunningTurn() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		let asked = clock.now.addingTimeInterval(-30)
		let question = ULID.generate(at: asked)
		let reply = ULID.generate(at: asked.addingTimeInterval(1))
		let turn = TurnID(ulid: question)
		let hugeReply = "Huge " + String(repeating: "h", count: historyBudget(clock: clock) * 4)
		try await seed(
			store,
			[
				seededRecord(
					store, at: asked, ulid: question,
					body: .synced(sampleUser(chatId: .main, text: "Short question?", turn: turn))),
				seededRecord(
					store, at: asked.addingTimeInterval(1), ulid: reply,
					body: .synced(sampleReply(chatId: .main, turn: turn, text: hugeReply))),
			])
		transport.summaryScript = [.text("Everything so far."), .finish(reason: .stop)]
		transport.script = [
			.text("Ok."), .finish(reason: .stop), .text("Ok again."), .finish(reason: .stop),
		]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let running = try #require(try await coach.send(draft("And now?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: running, in: .main))
		let userMessage = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.userMessage]), turn: running))
				.records.first?.ulid)
		let windows = try await store.fetch(
			RecordQuery(scope: .synced([.windowStart], includeLegacy: []))
		).records.compactMap { record -> ULID? in
			guard case .synced(.windowStart(let body)) = record.body else { return nil }
			return body.firstIncludedUlid
		}
		#expect(windows == [userMessage])
		let summaries = sent(.droppedSummary, by: transport)
		#expect(summaries.count == 1)
		let summarized = try #require(summaries.first).messages.map(\.unstampedContent).joined()
		#expect(summarized.contains("Question 0"))
		#expect(summarized.contains("Answer 0"))
		#expect(summarized.contains("Short question?"))
		#expect(summarized.contains(hugeReply))
		#expect(history.count == 1)
		_ = try await coach.sendAndSettle("And later?")
		for request in sent(.chatAttempt, by: transport) {
			#expect(!request.messages.contains { $0.unstampedContent == hugeReply })
			#expect(!request.messages.contains { $0.unstampedContent == "Short question?" })
		}
		#expect(sent(.chatAttempt, by: transport).count == 2)
		#expect(sent(.droppedSummary, by: transport).count == 1)
	}

	private func coverageConversation() -> Conversation {
		let records = [1, 3].flatMap { first in
			let turn = TurnID(ulid: fixedUlid(first))
			return [
				storedRecord(
					device: store.deviceId, wall: Int64(first), ulid: fixedUlid(first),
					body: .synced(sampleUser(chatId: .main, text: "Question", turn: turn))),
				storedRecord(
					device: store.deviceId, wall: Int64(first + 1), ulid: fixedUlid(first + 1),
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Reply"))),
			]
		}
		return ConversationFold.fold(chat: .main, synced: records, device: store.deviceId)
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
}
