import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ResetLeaseTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let host = ImmediateExecutionHost()
	let athleteLease = LeaseRequest(
		chat: .main, initiatedBy: .athlete, title: Catalog.chatNoticeWorking,
		language: .en)

	func coach() async -> Coach {
		await makeCoach(transport: transport, store: store, clock: clock, host: host)
	}

	func count(_ scope: RecordQuery.Scope) async throws -> Int {
		try await store.fetch(RecordQuery(scope: scope)).records.count
	}

	@Test func aNewConversationDuringRecoveryBeginsAnAthleteLeaseAtTheTap() async throws {
		let history = try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		let at = clock.now.addingTimeInterval(-5)
		try await seed(
			store,
			[
				seededRecord(
					store, at: at, ulid: ULID.generate(at: at),
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [history[0].user, history[0].reply]))))
			])
		transport.respond = ScriptedReply.sequence(
			[.finish(reason: .stop), .finish(reason: .stop)], for: .flush,
			requestDelay: .seconds(2), otherwise: transport.respond)
		let coach = await coach()
		await coach.lifecycle(.becameActive)
		try await waitUntil { host.leases.count == 1 }
		let resetting = startNewConversation(on: coach)
		try await waitUntil { host.leases.count == 2 }
		#expect(host.leases.map(\.request.initiatedBy) == [.recovery, .athlete])
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let athlete = try #require(await host.ended(1))
		#expect(athlete.request == athleteLease)
		#expect(athlete.kind == .continuedProcessing)
		#expect(athlete.ending == .finished(nil))
	}

	@Test func theChatShowsWorkingWhileTheResetSavesMemory() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Two rides."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await coach()
		_ = try await coach.sendAndSettle("How was my week?")
		transport.respond = ScriptedReply.sequence(
			[], for: .flush, requestDelay: .milliseconds(500), otherwise: transport.respond)
		let published = Task {
			var seen: [ChatSnapshot] = []
			for await snapshot in await coach.observe(.main) {
				seen.append(snapshot)
				if snapshot.opening != .continuing, snapshot.activity == .idle { break }
			}
			return seen
		}
		let resetting = startNewConversation(on: coach)
		try await waitUntil { !sent(.memoryFlush, by: transport).isEmpty }
		let saving = try #require(await coach.currentSnapshot(.main))
		#expect(saving.activity == .working(label: Catalog.chatNoticeStartingNewConversation))
		#expect(saving.opening == .continuing)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let started = try #require(await coach.currentSnapshot(.main))
		#expect(started.activity == .idle)
		#expect(started.opening.notice == Catalog.chatNoticeNewConversationSuccess)
		let snapshots = await published.value
		#expect(snapshots.contains { $0.activity != .idle })
		#expect(!snapshots.contains { $0.opening != .continuing && $0.activity != .idle })
	}

	@Test func aResetQueuedBehindAReplyShowsTheNewConversationWorkingRow() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is"), .hang], otherwise: transport.respond)
		let coach = await coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let resetting = startNewConversation(on: coach)
		try await Task.sleep(for: .milliseconds(200))
		#expect(
			await coach.currentSnapshot(.main)?.activity
				== .working(label: Catalog.chatNoticeStartingNewConversation))
		await coach.stop(.main)
		#expect(try await outcome(resetting) == .started(memory: .saved))
	}

	@Test func aNewConversationTappedDuringStopRunsAfterTheStopSettles() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is"), .hang], otherwise: transport.respond)
		let held = HeldAppendLog(inner: store, holding: "turnSettled", occurrence: 1)
		let coach = await makeCoach(transport: transport, store: held, clock: clock, host: host)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		async let stopped: Void = coach.stop(.main)
		var reached = held.reached.makeAsyncIterator()
		await reached.next()
		let resetting = startNewConversation(on: coach)
		try await Task.sleep(for: .milliseconds(200))
		#expect(resetting.landed == nil)
		#expect(sent(.memoryFlush, by: transport).isEmpty)
		held.release()
		await stopped
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let flushed = try #require(sent(.memoryFlush, by: transport).first)
		#expect(flushed.messages.contains { $0.unstampedContent == "Thursday?" })
		#expect(flushed.messages.contains { $0.unstampedContent == "Thursday is" })
		let archivedRef = try #require(try await coach.history().first?.id)
		let archived = try #require(try await coach.archivedConversation(archivedRef))
		#expect(archived.turns.map(\.id) == [turn])
		#expect(
			await coach.currentSnapshot(.main)?.opening.notice
				== Catalog.chatNoticeNewConversationSuccess)
	}

	@Test func stopKeepsANewConversationQueuedBehindTheStoppedReply() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is"), .hang], otherwise: transport.respond)
		let coach = await coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let resetting = startNewConversation(on: coach)
		try await Task.sleep(for: .milliseconds(200))
		await coach.stop(.main)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let archivedRef = try #require(try await coach.history().first?.id)
		let archived = try #require(try await coach.archivedConversation(archivedRef))
		#expect(archived.turns.map(\.id) == [turn])
		guard case .interrupted(let stopped)? = archived.turns.first?.state else {
			Issue.record("the stopped reply is not archived as interrupted")
			return
		}
		#expect(stopped.partial == "Thursday is")
		#expect(await host.ended(1)?.request == athleteLease)
		#expect(
			await coach.currentSnapshot(.main)?.opening.notice
				== Catalog.chatNoticeNewConversationSuccess)
	}

	@Test func expiryDuringTheResetFlushStartsTheConversationAndKeepsTheJob() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Two rides."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = await coach()
		_ = try await coach.sendAndSettle("How was my week?")
		transport.respond = ScriptedReply.sequence(
			[.hang], for: .flush, otherwise: transport.respond)
		let resetting = startNewConversation(on: coach)
		try await waitUntil { !sent(.memoryFlush, by: transport).isEmpty }
		await host.expire(.systemExpired)
		#expect(try await outcome(resetting) == .started(memory: .notSaved))
		#expect(try await count(.synced([.windowStart])) == 1)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening.notice == Catalog.chatNoticeNewConversationMemoryWarning)
		#expect(await host.ended(1)?.ending == .interrupted)
	}
}
