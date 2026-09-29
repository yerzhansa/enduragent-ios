import Foundation
import Testing

@testable import EnduragentCoach

extension FlushCoverageTests {
	@Test(arguments: [false, true])
	func resetDoesNotReplayAQuestionFromAPendingSupersededPartial(relaunch: Bool) async throws {
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		transport.script = [.text("Pending superseded partial"), .hang]
		let turn = try #require(
			try await coach.send(draft("Pending Saturday question"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		await coach.stop(.main)
		try #require(try #require(await coach.settledState(of: turn, in: .main)).retryable)
		transport.flushScript = Array(repeating: .fail(.http(status: 400)), count: 20)
		let longReply = String(repeating: "w", count: historyBudget(clock: clock) * 3)
		transport.script = [
			.text("First."), .finish(reason: .stop),
			.text("Second."), .finish(reason: .stop),
			.text(longReply), .finish(reason: .stop),
			.text("Ready."), .finish(reason: .stop),
		]
		for question in ["First question", "Second question", "Plan the week", "Anything else?"] {
			_ = try await coach.sendAndSettle(question)
		}
		try await waitUntil { sent(.memoryFlush, by: transport).count == 2 }
		let first = try #require(sent(.memoryFlush, by: transport).first)
		try #require(
			first.messages.contains { $0.unstampedContent == "Pending superseded partial" })
		transport.script = [.text("Replacement after pending"), .finish(reason: .stop)]
		try await coach.retry(turn, in: .main)
		try #require(
			replyText(try #require(await coach.settledState(of: turn, in: .main)))
				== "Replacement after pending")
		try await waitUntil { sent(.memoryFlush, by: transport).count == 4 }
		transport.flushScript = [.finish(reason: .stop)]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let saved = sent(.memoryFlush, by: transport)
		try #require(saved.count == 5)
		let reset = try #require(saved.last).messages.map(\.unstampedContent)
		try #require(reset.filter { $0 == "Pending Saturday question" }.count == 1)
		try #require(reset.filter { $0 == "Replacement after pending" }.count == 1)
		#expect(!reset.contains("Pending superseded partial"))
		let next = relaunch ? makeCoach(transport: transport, store: store, clock: clock) : coach
		if relaunch { await next.lifecycle(.becameActive) }
		#expect(await next.startNewConversation(in: .main) == .started(memory: .saved))
		let after = sent(.memoryFlush, by: transport)
		#expect(after.count == saved.count)
		let successfulRows = after.dropFirst(4).flatMap(\.messages).map(\.unstampedContent)
		#expect(successfulRows.filter { $0 == "Pending Saturday question" }.count == 1)
	}

	@Test func launchDrainsOnlyTheNewerJobCoveringASupersededPartial() async throws {
		let ledger = try await seedSupersededJobs(
			pending: [1, 2], newer: [1, 3, 4, 5], settled: false)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		await coach.lifecycle(.becameActive)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let requests = sent(.memoryFlush, by: transport)
		#expect(requests.count == 1)
		let rows = requests.flatMap(\.messages).map(\.unstampedContent)
		#expect(rows.filter { $0 == "Pending question" }.count == 1)
		#expect(rows.filter { $0 == "Replacement reply" }.count == 1)
		#expect(rows.filter { $0 == "Uncovered question" }.count == 1)
		#expect(rows.filter { $0 == "Uncovered reply" }.count == 1)
		#expect(!rows.contains("Superseded partial"))
		#expect(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).allSatisfy(\.saved)
		)
	}

	@Test(arguments: [false, true], [false, true])
	func aPendingJobKeepsRowsMissingFromANewerJob(implicit: Bool, newerSettled: Bool) async throws {
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		await coach.lifecycle(.becameActive)
		let ledger = try await seedSupersededJobs(
			pending: implicit ? [] : [1, 2, 4, 5], newer: [1, 3], settled: newerSettled)
		#expect(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).first?.settled
				== false)
		transport.flushScript = [.fail(.http(status: 400)), .fail(.http(status: 400))]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .notSaved))
		let failed = sent(.memoryFlush, by: transport)
		#expect(!failed.isEmpty)
		for request in failed {
			let rows = request.messages.map(\.unstampedContent)
			#expect(rows.contains("Uncovered question"))
			#expect(rows.contains("Uncovered reply"))
			#expect(!rows.contains("Superseded partial"))
		}
		#expect(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).first?.settled
				== false)
		transport.flushScript = [.finish(reason: .stop)]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let saved = try #require(sent(.memoryFlush, by: transport).last).messages.map(
			\.unstampedContent)
		#expect(saved.contains("Uncovered question"))
		#expect(saved.contains("Uncovered reply"))
		#expect(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).allSatisfy(\.saved)
		)
	}

	@Test func aSupersededOnlyJobDoesNotHideReplacementOrUnrelatedRows() async throws {
		let ledger = try await seedSupersededJobs(pending: [2], newer: [1], settled: true)
		transport.flushScript = [.fail(.http(status: 400)), .fail(.http(status: 400))]
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		await coach.lifecycle(.becameActive)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .notSaved))
		let requests = sent(.memoryFlush, by: transport)
		#expect(requests.count == 2)
		for request in requests {
			let rows = request.messages.map(\.unstampedContent)
			#expect(rows.filter { $0 == "Replacement reply" }.count == 1)
			#expect(rows.filter { $0 == "Uncovered question" }.count == 1)
			#expect(rows.filter { $0 == "Uncovered reply" }.count == 1)
			#expect(!rows.contains("Pending question"))
			#expect(!rows.contains("Superseded partial"))
		}
		let settlements = try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled])))
		#expect(settlements.records.count == 1)
		let pending = try #require(
			try await ledger.flushJobs(in: try await ledger.conversation(.main)).last)
		#expect(!pending.settled)
		#expect(pending.messages.count == 3)
		transport.flushScript = [.finish(reason: .stop)]
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let saved = try #require(sent(.memoryFlush, by: transport).last).messages.map(
			\.unstampedContent)
		#expect(saved.contains("Replacement reply"))
		#expect(saved.contains("Uncovered question"))
		#expect(saved.contains("Uncovered reply"))
	}

	private func seedSupersededJobs(pending: [Int], newer: [Int], settled: Bool) async throws
		-> Ledger
	{
		let ulids = (0...60).map {
			ULID.generate(at: clock.now.addingTimeInterval(TimeInterval(-100 + $0)))
		}
		let turn = TurnID(ulid: ulids[1])
		let process = ProcessID(ulid: ulids[60])
		var records: [(Int, RecordBody)] = [
			(1, .synced(sampleUser(chatId: .main, text: "Pending question", turn: turn))),
			(
				2,
				.synced(
					.turnSettled(
						TurnSettledBody(
							chatId: .main, turn: turn, attempt: AttemptID(ulid: ulids[2]),
							settlement: .interrupted(
								partial: "Superseded partial", cause: .athleteStopped, saved: .none)
						)))
			),
			(3, .synced(sampleReply(chatId: .main, turn: turn, text: "Replacement reply"))),
			(4, legacyUser(chatId: .main, text: "Uncovered question")),
			(5, legacyReply(chatId: .main, text: "Uncovered reply")),
			(
				10,
				.deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, messageUlids: pending.map { ulids[$0] },
							process: pending.isEmpty ? nil : process)))
			),
			(
				11,
				.deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, messageUlids: newer.map { ulids[$0] },
							process: process)))
			),
		]
		if settled {
			records.append(
				(
					12,
					.deviceLocal(
						.flushSettled(
							FlushSettledBody(
								chatId: .main, job: FlushJobID(ulid: ulids[11]),
								settlement: .saved(sections: 1, events: 0))))
				))
		}
		try await seed(
			store,
			records.map { offset, body in
				seededRecord(
					store, at: clock.now.addingTimeInterval(TimeInterval(-100 + offset)),
					ulid: ulids[offset], body: body)
			})
		return Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
	}
}
