import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension ResetWindowTests {
	@Test(arguments: [false, true])
	func skewedSendAfterObservedResetStaysCurrent(importBeforeLoad: Bool) async throws {
		let foreign = InMemoryRecordLog(deviceId: DeviceID(rawValue: "remote-phone"))
		let ahead = FixedClock(now: "1998-06-13T12:02:00+02:00", timeZone: "Europe/Amsterdam")
		let old = try #require(
			try await seedHistory(foreign, clock: ahead, turns: 1, tokens: 40).first)
		let remote = await makeCoach(transport: FakeModelTransport(), store: foreign, clock: ahead)
		#expect(await remote.startNewConversation(in: .main) == .started(memory: .saved))
		let imported = try await foreign.fetch(RecordQuery(scope: .everySynced)).records
		let store = ImportingRecordLog(inner: self.store)
		let coach = await coach(over: store)
		if !importBeforeLoad { _ = await coach.currentSnapshot(.main) }
		try await seed(store, imported)
		if !importBeforeLoad { store.notifyImport() }
		try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .seconds(5)) {
				$0.opening == .afterNewConversation(memorySaved: true)
			} != nil)
		transport.respond = ScriptedReply.sequence(
			[
				.text("Behind answer"), .finish(reason: .stop), .text("Next answer"),
				.finish(reason: .stop),
			],
			otherwise: transport.respond)
		let turn = try #require(
			try await coach.send(draft("Behind question"), to: .main).acceptedTurn)
		try await waitForRecords(.synced([.turnSettled]), count: 2, in: store)
		#expect(await coach.transcript(.main) == ["Behind question", "Behind answer"])
		let user = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.userMessage]), turn: turn)).records
				.first)
		let window = try #require(imported.first { $0.body.kind == "windowStart" })
		guard case .synced(.windowStart(let body)) = window.body else {
			Issue.record("Expected an imported reset")
			return
		}
		#expect(user.ulid < body.firstIncludedUlid)
		#expect(user.hlc > window.hlc)
		let reopened = await self.coach()
		#expect(await reopened.transcript(.main) == ["Behind question", "Behind answer"])
		let archive = try #require(try await reopened.history().first?.id)
		#expect(try await reopened.archivedConversation(archive)?.turns.map(\.id) == [old.turn])
		_ = try #require(try await reopened.send(draft("Next question"), to: .main).acceptedTurn)
		try await waitForRecords(.synced([.turnSettled]), count: 3, in: store)
		let prompt = try #require(sent(.chatAttempt, by: transport).last).messages.map(
			\.unstampedContent)
		#expect(prompt.dropLast().suffix(2) == ["Behind question", "Behind answer"])
		#expect(prompt.last?.hasPrefix("Next question") == true)
		#expect(!prompt.contains("Question 0"))
		#expect(try await reopened.history().count == 1)
		#expect(await reopened.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(await reopened.transcript(.main).isEmpty)
		let localWindow = try #require(
			try await store.fetch(
				RecordQuery(scope: .synced([.windowStart]), writtenBy: store.deviceId)
			).records.first)
		guard case .synced(.windowStart(let localBody)) = localWindow.body else {
			Issue.record("Expected a local reset")
			return
		}
		#expect(localBody.firstIncludedUlid < body.firstIncludedUlid)
		#expect(
			try await reopened.history().map(\.firstQuestion) == ["Behind question", "Question 0"])
		let final = await self.coach()
		#expect(await final.transcript(.main).isEmpty)
		#expect(try await final.history() == reopened.history())
	}

	@Test func aResetImportedMidTurnKeepsItsLateReplyWithItsQuestion() async throws {
		let held = HeldAppendLog(inner: store, holding: "turnSettled", occurrence: 1)
		defer { held.release() }
		let importing = ImportingRecordLog(inner: held)
		let coach = await coach(over: importing)
		transport.respond = ScriptedReply.sequence(
			[.text("Late answer"), .finish(reason: .stop)], otherwise: transport.respond)
		let local = try #require(
			try await coach.send(draft("Earlier question"), to: .main).acceptedTurn)
		let parked = try await beforeDeadline(within: .seconds(5)) {
			var reached = held.reached.makeAsyncIterator()
			return await reached.next() != nil
		}
		try #require(parked == true)
		let foreign = InMemoryRecordLog(deviceId: DeviceID(rawValue: "remote-phone"))
		let ahead = FixedClock(now: "1998-06-13T12:02:00+02:00", timeZone: "Europe/Amsterdam")
		let remote = await makeCoach(transport: FakeModelTransport(), store: foreign, clock: ahead)
		#expect(await remote.startNewConversation(in: .main) == .started(memory: .saved))
		try await seed(importing, try await foreign.fetch(RecordQuery(scope: .everySynced)).records)
		importing.notifyImport()
		try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .seconds(5)) {
				$0.opening == .afterNewConversation(memorySaved: true)
			} != nil)
		#expect(await coach.transcript(.main).isEmpty)
		held.release()
		try await waitForRecords(.synced([.turnSettled]), count: 1, in: store)
		#expect(await coach.transcript(.main).isEmpty)
		let archived = try #require(try await coach.history().first?.id)
		let liveHistory = try #require(try await coach.archivedConversation(archived))
		#expect(liveHistory.turns.map(\.id) == [local])
		#expect(replyText(try #require(liveHistory.turns.first?.state)) == "Late answer")
		let reopened = await self.coach()
		#expect(await reopened.transcript(.main).isEmpty)
		#expect(try await reopened.archivedConversation(archived) == liveHistory)
	}
}
