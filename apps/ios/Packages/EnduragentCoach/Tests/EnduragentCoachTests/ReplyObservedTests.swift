import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReplyObservedTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func replyObservedIsWrittenBeforeFirstDeltaIsPublished() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday "), .text("is on."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let gate = HeldAppendLog(inner: store, holding: "replyObserved", occurrence: 1)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: gate, clock: clock)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		var held = gate.reached.makeAsyncIterator()
		_ = await held.next()
		let whileHeld = try #require(await coach.currentSnapshot(.main))
		guard case .processing? = whileHeld.turns.first?.state else {
			Issue.record("expected processing, got \(String(describing: whileHeld.turns.first))")
			return
		}
		#expect(whileHeld.liveReply?.text.isEmpty != false)
		gate.release()
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "Thursday is on.")
		let marks = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.replyObserved]), turn: turn)
		).records
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)
		).records
		#expect(marks.count == 1)
		#expect(marks.first?.cause == claims.first?.cause)
	}

	@Test func replyObservedIsFoldedAfterRelaunch() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let coach = await makeCoach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let synced = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: .main))
		let local = try await ledger.read(
			RecordQuery(scope: ConversationFold.localScope, chatId: .main))
		let facts = try #require(
			ConversationFold.fold(
				chat: .main, synced: synced.records, local: local.records, device: store.deviceId
			).turn(turn))
		let attempt = try #require(facts.claims.first?.attempt)
		#expect(facts.replyObserved.map(\.attempt) == [attempt])
		#expect(
			TurnLifecycle.observeReply(attempt, on: facts, chat: .main) == nil)
	}

	@Test func textThenMemoryWriteThenServerErrorSettlesSavedUnverified() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.text("Noted. "),
				.toolCall(
					name: "memory_write",
					arguments:
						#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
				),
				.finish(reason: .toolCalls),
				.fail(.http(status: 500)),
				.text("Never sent."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let settled = try await makeCoach().sendAndSettle("Remember my Saturday ride")
		guard case .savedWork(let savedWork) = settled else {
			Issue.record("expected saved work, got \(settled)")
			return
		}
		#expect(savedWork.outcome == .savedUnverified)
		#expect(savedWork.notice.action == nil)
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 2)
	}

	@Test func observedTextBelongsToOneGenerateAttempt() async throws {
		transport.finishUsage = Usage(
			inputTokens: TurnPolicy.contextWindowCap, outputTokens: 8, cost: nil)
		transport.respond = ScriptedReply.sequence(
			[
				.text("truncated"), .finish(reason: .length),
				.fail(.http(status: 500)),
				.text("after compact"), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		let turn = try #require(try await coach.send(draft("Long history"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "after compact")
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 3)
		let marks = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.replyObserved]), turn: turn)
		).records
		#expect(marks.count == 1)
	}

	@Test func anUnsavedReplyMarkIsReportedOncePerAttempt() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("One "), .text("two "), .text("three."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let faulty = FaultInjectingRecordLog(wrapping: store)
		try faulty.failAppends(ofKind: "replyObserved")
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: faulty, clock: clock)
		let settled = try await coach.sendAndSettle("Count to three")
		#expect(replyText(settled) == "One two three.")
		let unsaved = coach.diagnostics.entries.filter { entry in
			if case .replyObservedUnsaved = entry.event { return true }
			return false
		}
		#expect(unsaved.count == 1)
	}

	private func makeCoach() async -> Coach {
		await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)
	}
}
