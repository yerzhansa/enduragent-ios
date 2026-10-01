import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FlushDeadlineTests {
	@Test(arguments: [nil, "7", "120", "4", "10"] as [String?])
	func aRateLimitedDrainDoesNotHoldTheNextTurnPastTheCap(retryAfter: String?) async throws {
		let waits = AsyncStream<Duration>.makeStream()
		let clock = HeldClock { waits.continuation.yield($0) }
		let store = InMemoryRecordLog()
		let transport = FakeModelTransport()
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 9 / 10)
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		transport.flushScript = failures(retryAfter: retryAfter)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		_ = try await coach.sendAndSettle("Rest day?")
		transport.script = [.text("Second reply."), .hang]
		let next = try #require(try await coach.send(draft("Next?"), to: .main).acceptedTurn)
		let visibleReply = Task {
			await coach.waitForLiveText(next)
			waits.continuation.finish()
		}
		for await duration in waits.stream {
			#expect(clock.uptime + duration <= .seconds(10))
			clock.release(duration)
		}
		await visibleReply.value
		#expect(clock.uptime <= .seconds(10))
		#expect(sent(.chatAttempt, by: transport).count == 2)
		#expect(sent(.memoryFlush, by: transport).map(\.deadline) == deadlines(retryAfter))
		try await expectPending(in: store, clock: clock)
		await coach.lifecycle(.willTerminate)
	}

	@Test(arguments: [nil, "7", "120", "4", "10"] as [String?])
	func aRateLimitedSaveDoesNotHoldNewConversationPastTheCap(retryAfter: String?) async throws {
		let waits = AsyncStream<Duration>.makeStream()
		let clock = HeldClock { waits.continuation.yield($0) }
		let store = InMemoryRecordLog()
		let transport = FakeModelTransport()
		try await seedHistory(store, clock: clock, turns: 1, tokens: 200)
		transport.flushScript = failures(retryAfter: retryAfter)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		let reset = Task {
			let outcome = await coach.startNewConversation(in: .main)
			waits.continuation.finish()
			return outcome
		}
		for await duration in waits.stream {
			#expect(clock.uptime + duration <= .seconds(10))
			clock.release(duration)
		}
		#expect(await reset.value == .started(memory: .notSaved))
		#expect(clock.uptime <= .seconds(10))
		#expect(sent(.memoryFlush, by: transport).map(\.deadline) == deadlines(retryAfter))
		try await expectPending(in: store, clock: clock)
		let boundaries = try await store.fetch(RecordQuery(scope: .synced([.windowStart]))).records
		#expect(boundaries.count == 1)
	}

	private func failures(retryAfter: String?) -> [ScriptedEvent] {
		let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]
		return Array(repeating: .fail(.http(status: 429, headers: headers)), count: 4)
	}

	private func deadlines(_ retryAfter: String?) -> [Duration] {
		switch retryAfter {
		case "120": [.seconds(600)]
		case "4": Array(repeating: .seconds(600), count: 3)
		default: Array(repeating: .seconds(600), count: 2)
		}
	}

	private func expectPending(in store: InMemoryRecordLog, clock: HeldClock) async throws {
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
		#expect(jobs.count == 1)
		#expect(jobs.allSatisfy { $0.phase == .pending })
		#expect(clock.held.isEmpty)
	}
}
