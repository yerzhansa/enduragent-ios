import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct UnrecoveredClaimTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func aDeadClaimShowsHistoryUnavailableWhileRecoveryCannotRead() async throws {
		let transport = FakeModelTransport()
		transport.respond = { _ in ScriptedReply([.hang]) }
		let store = InMemoryRecordLog()
		let dying = FaultInjectingRecordLog(wrapping: store)
		let before = await makeCoach(transport: transport, store: dying, clock: clock)
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.waitUntilProcessing(turn)
		try await before.dieWithoutWriting(to: dying)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], for: .chat)
		let requestsBefore = transport.requests.count
		let log = FaultInjectingRecordLog(wrapping: store)
		log.failRecoveryReads = true
		let after = await makeCoach(transport: transport, store: log, clock: clock)
		await after.lifecycle(.becameActive)
		#expect(
			await after.state(of: turn)
				== .unrecovered(
					TurnState.Unrecovered(
						notice: AthleteNotice(key: Catalog.chatHistoryFailure, actions: []))))
		await #expect(throws: RetryRefusal.unrecovered) {
			try await after.retry(turn, in: .main)
		}
		#expect(transport.requests.count == requestsBefore)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
				.isEmpty)
		log.failRecoveryReads = false
		await after.lifecycle(.becameActive)
		let recovered = try #require(await after.state(of: turn))
		guard case .interrupted(let interrupted) = recovered else {
			Issue.record("expected interrupted once recovery reads, got \(recovered)")
			return
		}
		#expect(interrupted.cause == .processEnded)
		#expect(interrupted.notice.actions == [.tryAgain(turn)])
		try await after.retry(turn, in: .main)
		let replied = try await after.waitForState(of: turn) { $0.flatMap(replyText) != nil }
		#expect(replied.flatMap(replyText) == "Thursday is on.")
	}

	@Test func aSavedDeadClaimWhileRecoveryCannotReadOffersNoReplay() async throws {
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "memory_write",
					arguments:
						#"{"type":"memory","section":"schedule","content":"Group ride on Saturdays."}"#
				),
				.finish(reason: .toolCalls),
				.hang,
			], otherwise: transport.respond)
		let store = InMemoryRecordLog()
		let dying = FaultInjectingRecordLog(wrapping: store)
		let before = await makeCoach(transport: transport, store: dying, clock: clock)
		let turn = try #require(
			try await before.send(draft("Remember my Saturday ride"), to: .main).acceptedTurn)
		try await waitForRecords(.synced([.memorySection]), count: 1, in: store)
		try await before.dieWithoutWriting(to: dying)
		let requestsBefore = transport.requests.count
		transport.respond = ScriptedReply.sequence(
			[.text("Noted again."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let log = FaultInjectingRecordLog(wrapping: store)
		log.failRecoveryReads = true
		let after = await makeCoach(transport: transport, store: log, clock: clock)
		await after.lifecycle(.becameActive)
		let state = try #require(await after.state(of: turn))
		#expect((turnNotice(of: state)?.actions ?? []).isEmpty)
		await #expect(throws: RetryRefusal.unrecovered) {
			try await after.retry(turn, in: .main)
		}
		try await Task.sleep(for: .milliseconds(300))
		#expect(transport.requests.count == requestsBefore)
		log.failRecoveryReads = false
		await after.lifecycle(.becameActive)
		let recovered = try #require(await after.state(of: turn))
		guard case .interrupted(let interrupted) = recovered else {
			Issue.record("expected interrupted once recovery reads, got \(recovered)")
			return
		}
		#expect(interrupted.notice.key == Catalog.chatTurnInterruptedSomeSaved)
		#expect(interrupted.notice.actions.isEmpty)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await after.retry(turn, in: .main)
		}
		#expect(transport.requests.count == requestsBefore)
	}
}
