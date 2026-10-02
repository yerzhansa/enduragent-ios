import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ResetAdmissionTests {
	@Test func slashStartReturnsWhileTheEarlierReplyIsHeld() async throws {
		let store = InMemoryRecordLog()
		let nextReply = HeldAppendLog(inner: store, holding: "turnClaim", occurrence: 2)
		let memory = HeldAppendLog(inner: nextReply, holding: "flushPending", occurrence: 1)
		let held = HeldAppendLog(inner: memory, holding: "turnSettled", occurrence: 1)
		defer {
			held.release()
			memory.release()
			nextReply.release()
		}
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.text("Old answer"), .finish(reason: .stop), .text("New answer"),
				.finish(reason: .stop),
			],
			otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: held)
		let first = try #require(
			try await coach.send(draft("Old question"), to: .main).acceptedTurn)
		let reached = try await beforeDeadline(within: .hangGuard) {
			var events = held.reached.makeAsyncIterator()
			return await events.next() != nil
		}
		try #require(reached == true)
		let admitted = try await beforeDeadline(
			within: .subject(.seconds(1)),
			onTimeout: {
				held.release()
				memory.release()
				nextReply.release()
			}
		) {
			try await coach.send(draft("/start"), to: .main)
		}
		let admission = try #require(
			admitted, "New conversation must return admission while the earlier reply is held")
		guard case .newConversation(.accepted(let reset)) = admission else {
			Issue.record("Expected an accepted reset")
			return
		}
		let next = try #require(try await coach.send(draft("New question"), to: .main).acceptedTurn)
		let waiting = try #require(await coach.currentSnapshot(.main))
		#expect(waiting.turns.map(\.id) == [first])
		#expect(waiting.reset == .waiting(reset))
		let phrasebook = CatalogPhrasebook(tag: .en)
		if case .working(let label) = waiting.activity {
			#expect(phrasebook.say(label, [:]) == "Starting a new conversation…")
		} else {
			Issue.record("The waiting conversation must have one working row")
		}
		held.release()
		try await parked(memory)
		let saving = try #require(await coach.currentSnapshot(.main))
		#expect(saving.reset == .waiting(reset))
		#expect(saving.turns.map(\.id) == [first])
		#expect(saving.activity == .working(label: Catalog.chatNoticeStartingNewConversation))
		memory.release()
		let opened = try await firstSnapshot(
			in: await coach.observe(.main), within: .subject(.seconds(1))
		) {
			$0.opening.showsWelcome && $0.turns.map(\.id) == [next]
		}
		#expect(try #require(opened).opening == .afterNewConversation(reset: reset, memory: .saved))
		try await parked(nextReply)
		nextReply.release()
		_ = try #require(await coach.settledState(of: next, in: .main, within: .hangGuard))
		let history = try #require(try await coach.history().first?.id)
		#expect(try await coach.archivedConversation(history)?.turns.map(\.id) == [first])
		let prompt = try #require(sent(.chatAttempt, by: transport).last)
		#expect(!prompt.messages.contains { $0.content.contains("Old question") })
		#expect(prompt.messages.contains { $0.content.contains("New question") })
	}
	@Test(arguments: ["flushPending", "windowStart"])
	func anAcceptedResetPublishesALaterStorageFailure(kind: String) async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let held = HeldAppendLog(inner: faults, holding: "turnSettled", occurrence: 1)
		defer { held.release() }
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.text("Old answer"), .finish(reason: .stop), .text("New answer"),
				.finish(reason: .stop),
			],
			otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: held)
		_ = try await coach.send(draft("Old question"), to: .main)
		try await parked(held)
		try faults.failAppends(ofKind: kind)
		let admission = try await beforeDeadline(within: .hangGuard, onTimeout: held.release) {
			try await coach.send(draft("/start"), to: .main)
		}
		guard
			case .newConversation(.accepted(let reset)) = try #require(admission)
		else {
			Issue.record("Expected accepted admission before the later failure")
			return
		}
		let next = try #require(try await coach.send(draft("New question"), to: .main).acceptedTurn)
		held.release()
		let failed = try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
			$0.reset == .failed(reset, failure: .local(.recordStorage))
		}
		#expect(try #require(failed).turns.count == 2)
		_ = try #require(await coach.settledState(of: next, in: .main, within: .hangGuard))
		#expect(
			await coach.transcript(.main) == [
				"Old question", "Old answer", "New question", "New answer",
			])
		#expect(try await coach.history().isEmpty)
	}

	@Test func anOlderCompletionKeepsTheNewerResetWaiting() async throws {
		let store = InMemoryRecordLog()
		let secondFlush = HeldAppendLog(inner: store, holding: "flushPending", occurrence: 2)
		let held = HeldAppendLog(inner: secondFlush, holding: "turnSettled", occurrence: 1)
		defer {
			held.release()
			secondFlush.release()
		}
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.text("Old answer"), .finish(reason: .stop), .text("Middle answer"),
				.finish(reason: .stop),
				.text("New answer"), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: held)
		_ = try await coach.send(draft("Old question"), to: .main)
		try await parked(held)
		_ = try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					held.release()
					secondFlush.release()
				}
			) {
				try await coach.send(draft("/start"), to: .main)
			})
		let middle = try #require(
			try await coach.send(draft("Middle question"), to: .main).acceptedTurn)
		let admission = try await beforeDeadline(
			within: .hangGuard,
			onTimeout: {
				held.release()
				secondFlush.release()
			}
		) {
			try await coach.send(draft("/start"), to: .main)
		}
		guard
			case .newConversation(.accepted(let reset)) = try #require(admission)
		else {
			Issue.record("Expected second reset admission")
			return
		}
		let next = try #require(try await coach.send(draft("New question"), to: .main).acceptedTurn)
		held.release()
		try await parked(secondFlush)
		let waiting = try #require(await coach.currentSnapshot(.main))
		#expect(waiting.reset == .waiting(reset))
		#expect(waiting.turns.map(\.id) == [middle])
		secondFlush.release()
		let opened = try await firstSnapshot(
			in: await coach.observe(.main), within: .subject(.seconds(1))
		) {
			$0.opening == .afterNewConversation(reset: reset, memory: .saved)
		}
		#expect(try #require(opened).turns.map(\.id) == [next])
	}

	@Test func anImportedReplacementClearsObsoleteWaiting() async throws {
		let held = HeldAppendLog(inner: InMemoryRecordLog(), holding: "turnSettled", occurrence: 1)
		defer { held.release() }
		let importing = ImportingRecordLog(inner: held)
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[.text("Old answer"), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: importing)
		_ = try await coach.send(draft("Old question"), to: .main)
		try await parked(held)
		_ = try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: held.release) {
				try await coach.send(draft("/start"), to: .main)
			})
		let foreign = InMemoryRecordLog(deviceId: DeviceID(rawValue: "remote-phone"))
		let ahead = FixedClock(now: "1998-06-13T12:02:00+02:00", timeZone: "Europe/Amsterdam")
		let remote = await makeCoach(transport: FakeModelTransport(), store: foreign, clock: ahead)
		#expect(await remote.resetAndSettle(in: .main) == .started(memory: .saved))
		let replacement = try #require(await remote.currentSnapshot(.main)).opening
		try await seed(importing, try await foreign.fetch(RecordQuery(scope: .everySynced)).records)
		importing.notifyImport()
		let replaced = try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
			$0.reset == .idle && $0.opening == replacement
		}
		try #require(replaced != nil)
		held.release()
		try await waitForRecords(
			.synced([.windowStart]), count: 2, in: importing, within: .hangGuard)
		#expect(await coach.currentSnapshot(.main)?.opening == replacement)
		#expect(await coach.currentSnapshot(.main)?.reset == .idle)
	}

	private func parked(_ held: HeldAppendLog) async throws {
		let reached = try await beforeDeadline(within: .hangGuard, onTimeout: held.release) {
			var events = held.reached.makeAsyncIterator()
			return await events.next() != nil
		}
		try #require(reached == true)
	}

}
