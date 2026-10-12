import EnduragentCoachFixtures
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
			transport.respond = ScriptedReply.sequence(
				[.text("Answer \(index) " + answer), .finish(reason: .stop)], for: .chat,
				otherwise: transport.respond)
			let turn = try #require(
				try await coach.send(draft("Question \(index)"), to: .main).acceptedTurn)
			_ = try #require(await coach.settledState(of: turn, in: .main))
			preceding.append(turn)
		}
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier conversation."), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		switch ending {
		case .reply:
			transport.respond = ScriptedReply.sequence(
				[.text("Thursday is on."), .finish(reason: .stop)], otherwise: transport.respond)
		case .stop:
			transport.respond = ScriptedReply.sequence(
				[.text("Thursday is"), .hang], otherwise: transport.respond)
		case .failure:
			transport.respond = ScriptedReply.sequence(
				[.fail(.http(status: 400))], otherwise: transport.respond)
		}
		let turn = try #require(
			try await coach.send(draft("Is Thursday on?"), to: .main).acceptedTurn)
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { flush.release() }) {
				await flush.reached.first { _ in true } != nil
			} == true)
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
		let live = await coach.currentSnapshot(.main)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		#expect(live == (await reopened.currentSnapshot(.main)))
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let reloaded = try await ledger.conversation(.main)
		let jobs = try await ledger.flushJobs(in: reloaded)
		let expected = reloaded.messagesSinceLastFlush(jobs, excluding: nil)
		#expect(
			reloaded.current.promptHistory(
				excluding: nil, for: testConnection.account, device: store.deviceId,
				using: reloaded.ownership
			).summary == "Earlier conversation.")
		#expect(
			!reloaded.current.promptHistory(
				excluding: nil, for: testConnection.account, device: store.deviceId,
				using: reloaded.ownership
			).ulids.contains(
				try #require(preceding.first).ulid))
		#expect(expected.contains { $0.message.text.hasPrefix("Answer 1 ") })
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let pending = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.flushPending]), chatId: .main)
		).records
		guard case .deviceLocal(.flushPending(let flushed)) = try #require(pending.last).body else {
			Issue.record("expected the live reset to flush the retained conversation")
			return
		}
		#expect(flushed.messageUlids == expected.map(\.ulid))
		let request = try #require(sent(.memoryFlush, by: transport).last)
		for row in expected {
			#expect(request.messages.contains { $0.unstampedContent == row.message.text })
		}
	}

	@Test func resetBoundaryFromAnyDeviceSplitsSegments() throws {
		let before = TurnID(ulid: fixedUlid(1))
		let after = TurnID(ulid: fixedUlid(4))
		let resetId = ResetID(ulid: fixedUlid(3))
		let records = [
			foldRow(1, phoneA, .synced(sampleUser(chatId: .main, text: "before", turn: before))),
			foldRow(
				2, phoneA, .synced(sampleReply(chatId: .main, turn: before, text: "before reply"))),
			foldRow(
				3, phoneB,
				.synced(
					.windowStart(
						WindowStartBody(
							chatId: .main, firstIncludedUlid: fixedUlid(3),
							reason: .reset(resetId))))),
			foldRow(4, phoneA, .synced(sampleUser(chatId: .main, text: "after", turn: after))),
			foldRow(
				5, phoneA, .synced(sampleReply(chatId: .main, turn: after, text: "after reply"))),
		]
		let conversation = ConversationFold.fold(chat: .main, synced: records, device: phoneA)
		#expect(conversation.segments.count == 2)
		#expect(conversation.segments[0].openedBy == .chatStart)
		#expect(conversation.segments[0].messages.map(\.text) == ["before", "before reply"])
		#expect(conversation.current.openedBy == .reset(resetId))
		#expect(conversation.current.id == SegmentID(boundary: fixedUlid(3)))
		#expect(conversation.current.messages.map(\.text) == ["after", "after reply"])
		#expect(
			conversation.current.promptHistory(
				excluding: after, for: testConnection.account, device: phoneA,
				using: conversation.ownership
			).messages.isEmpty)
	}

	@Test func appliedResetMovesTurnsFromItsBoundaryOnIntoTheNewSegment() throws {
		let before = TurnID(ulid: fixedUlid(1))
		let after = TurnID(ulid: fixedUlid(4))
		let resetId = ResetID(ulid: fixedUlid(3))
		let folded = ConversationFold.fold(
			chat: .main,
			synced: [
				foldRow(
					1, phoneA, .synced(sampleUser(chatId: .main, text: "before", turn: before))),
				foldRow(
					4, wall: 2, phoneA,
					.synced(sampleUser(chatId: .main, text: "after", turn: after))),
			], device: phoneA)
		#expect(folded.segments.count == 1)
		let boundary = foldRow(
			5, wall: 3, phoneA,
			.synced(
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: fixedUlid(3),
						reason: .reset(resetId)))))
		var applied = folded
		applied.apply([boundary], device: phoneA)
		#expect(applied.segments.map(\.turns.count) == [1, 1])
		#expect(applied.segments[0].turns.map(\.turn) == [before])
		#expect(applied.current.openedBy == .reset(resetId))
		#expect(applied.current.id == SegmentID(boundary: fixedUlid(3)))
		#expect(applied.current.turns.map(\.turn) == [after])
	}

}
