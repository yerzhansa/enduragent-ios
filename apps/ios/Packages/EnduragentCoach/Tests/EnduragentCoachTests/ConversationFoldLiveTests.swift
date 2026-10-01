import Foundation
import Testing

@testable import EnduragentCoach

extension ConversationFoldTests {
	enum TrimmedAttemptEnd: CaseIterable, Sendable {
		case reply
		case stop
		case failure
	}

	@Test(arguments: TrimmedAttemptEnd.allCases)
	func liveTrimMatchesReload(ending: TrimmedAttemptEnd) async throws {
		let store = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let transport = FakeModelTransport()
		let faults = FaultInjectingRecordLog(wrapping: store)
		let flush = HeldAppendLog(inner: faults, holding: "flushPending", occurrence: 1)
		defer { flush.release() }
		let coach = await makeCoach(transport: transport, store: flush, clock: clock)
		var preceding: [TurnID] = []
		let answer = String(repeating: "w", count: historyBudget(clock: clock) * 2)
		for index in 0..<2 {
			transport.script = [.text("Answer \(index) " + answer), .finish(reason: .stop)]
			let turn = try #require(
				try await coach.send(draft("Question \(index)"), to: .main).acceptedTurn)
			_ = try #require(await coach.settledState(of: turn, in: .main))
			preceding.append(turn)
		}
		transport.summaryScript = [.text("Earlier conversation."), .finish(reason: .stop)]
		switch ending {
		case .reply: transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		case .stop: transport.script = [.text("Thursday is"), .hang]
		case .failure: transport.script = [.fail(.http(status: 400))]
		}
		let turn = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		var saving = flush.reached.makeAsyncIterator()
		_ = await saving.next()
		faults.failNextAppend = true
		flush.release()
		if ending == .stop {
			await coach.waitForLiveText(turn)
			await coach.stop(.main)
		}
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		switch ending {
		case .reply: #expect(replyText(settled) == "Thursday is on.")
		case .stop: #expect(isInterrupted(settled))
		case .failure: #expect(failure(settled) != nil)
		}
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let reloaded = try await ledger.conversation(.main)
		let jobs = try await ledger.flushJobs(in: reloaded)
		let expected = reloaded.messagesSinceLastFlush(jobs, excluding: nil)
		#expect(reloaded.current.promptHistory(excluding: nil).summary == "Earlier conversation.")
		#expect(
			!reloaded.current.promptHistory(excluding: nil).ulids.contains(
				try #require(preceding.first).ulid))
		#expect(expected.contains { $0.message.text.hasPrefix("Answer 1 ") })
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let pending = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.flushPending]), chatId: .main)
		).records
		guard case .deviceLocal(.flushPending(let flushed)) = try #require(pending.last).body else {
			Issue.record("expected the live reset to flush the retained conversation")
			return
		}
		#expect(flushed.messageUlids == expected.map(\.ulid))
		let request = try #require(sent(.memoryFlush, by: transport).last)
		for (_, message) in expected {
			#expect(request.messages.contains { $0.unstampedContent == message.text })
		}
	}
}
