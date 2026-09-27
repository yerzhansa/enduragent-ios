import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ResetLeaseTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let host = ImmediateExecutionHost()
	let athleteLease = LeaseRequest(
		chat: .main, initiatedBy: .athlete, title: Catalog.chatNoticeWorking)

	func coach() -> Coach {
		makeCoach(transport: transport, store: store, clock: clock, host: host)
	}

	func count(_ scope: RecordQuery.Scope) async throws -> Int {
		try await store.fetch(RecordQuery(scope: scope)).records.count
	}

	func startNewConversation(on coach: Coach) -> PendingOutcome {
		let pending = PendingOutcome()
		Task { pending.land(await coach.startNewConversation(in: .main)) }
		return pending
	}

	func outcome(_ pending: PendingOutcome) async throws -> ResetOutcome? {
		let deadline = ContinuousClock.now + .seconds(10)
		while pending.landed == nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		return pending.landed
	}

	func waitFor(_ condition: () async throws -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(5)
		while try await !condition(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
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
								chatId: .main, trigger: .softThreshold,
								messageUlids: [history[0].user, history[0].reply]))))
			])
		transport.requestDelay = .seconds(2)
		transport.flushScript = [.finish(reason: .stop), .finish(reason: .stop)]
		let coach = coach()
		await coach.lifecycle(.becameActive)
		try await waitFor { host.leases.count == 1 }
		let resetting = startNewConversation(on: coach)
		try await waitFor { host.leases.count == 2 }
		#expect(host.leases.map(\.request.initiatedBy) == [.recovery, .athlete])
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let athlete = try #require(await host.ended(1))
		#expect(athlete.request == athleteLease)
		#expect(athlete.kind == .continuedProcessing)
		#expect(athlete.ending == .finished(nil))
	}

	@Test func theChatShowsWorkingWhileTheResetSavesMemory() async throws {
		transport.script = [.text("Two rides."), .finish(reason: .stop)]
		let coach = coach()
		_ = try await coach.sendAndSettle("How was my week?")
		transport.requestDelay = .milliseconds(500)
		let resetting = startNewConversation(on: coach)
		try await waitFor { !sent(.memoryFlush, by: transport).isEmpty }
		let saving = try #require(await coach.currentSnapshot(.main))
		#expect(saving.activity == .startingNewConversation(label: Catalog.chatNoticeWorking))
		#expect(saving.opening == .continuing)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let started = try #require(await coach.currentSnapshot(.main))
		#expect(started.activity == .idle)
		#expect(started.opening == .afterNewConversation(memorySaved: true))
	}

	@Test func aResetQueuedBehindAReplyLeavesTheWorkingRowToTheReply() async throws {
		transport.script = [.text("Thursday is"), .hang]
		let coach = coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let resetting = startNewConversation(on: coach)
		try await Task.sleep(for: .milliseconds(200))
		#expect(
			await coach.currentSnapshot(.main)?.activity
				== .working(label: Catalog.chatNoticeWorking))
		await coach.stop(.main)
		#expect(try await outcome(resetting) == .started(memory: .saved))
	}

	@Test func stopKeepsANewConversationQueuedBehindTheStoppedReply() async throws {
		transport.script = [.text("Thursday is"), .hang]
		let coach = coach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let resetting = startNewConversation(on: coach)
		try await waitFor { await coach.currentSnapshot(.main)?.activity != .idle }
		try await Task.sleep(for: .milliseconds(200))
		await coach.stop(.main)
		#expect(try await outcome(resetting) == .started(memory: .saved))
		let archived = try #require(try await coach.history().first)
		#expect(archived.turns.map(\.id) == [turn])
		guard case .interrupted(let stopped)? = archived.turns.first?.state else {
			Issue.record("the stopped reply is not archived as interrupted")
			return
		}
		#expect(stopped.partial == "Thursday is")
		#expect(await host.ended(1)?.request == athleteLease)
		#expect(
			await coach.currentSnapshot(.main)?.opening == .afterNewConversation(memorySaved: true))
	}

	@Test func expiryDuringTheResetFlushStartsTheConversationAndKeepsTheJob() async throws {
		transport.script = [.text("Two rides."), .finish(reason: .stop)]
		let coach = coach()
		_ = try await coach.sendAndSettle("How was my week?")
		transport.flushScript = [.hang]
		let resetting = startNewConversation(on: coach)
		try await waitFor { !sent(.memoryFlush, by: transport).isEmpty }
		await host.expire(.systemExpired)
		#expect(try await outcome(resetting) == .started(memory: .notSaved))
		#expect(try await count(.synced([.windowStart])) == 1)
		#expect(try await count(.deviceLocal([.flushPending])) == 1)
		#expect(try await count(.deviceLocal([.flushSettled])) == 0)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .afterNewConversation(memorySaved: false))
		#expect(await host.ended(1)?.ending == .interrupted)
	}
}

final class PendingOutcome: Sendable {
	private let outcome = Mutex<ResetOutcome?>(nil)

	var landed: ResetOutcome? {
		outcome.withLock { $0 }
	}

	func land(_ value: ResetOutcome) {
		outcome.withLock { $0 = value }
	}
}
