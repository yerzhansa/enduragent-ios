import Foundation
import Testing

@testable import EnduragentCoach

private let phone = DeviceID(rawValue: "phone-a")
private let rateLimitedTurn = TurnID(ulid: fixedUlid(40))
private let failedAttempt = AttemptID(ulid: fixedUlid(41))

private func rateLimited(_ retryAfter: Duration?) -> Settlement {
	.failed(.model(.rateLimited(retryAfter: retryAfter)), saved: .none)
}

private func action(in snapshot: ChatSnapshot?) -> RecoveryAction? {
	guard
		case .failed(let failed)? = snapshot?.turns.first(where: { $0.id == rateLimitedTurn })?
			.state
	else { return nil }
	return failed.notice.action
}

private func first(
	in stream: AsyncStream<ChatSnapshot>, within limit: Duration,
	where matches: @escaping @Sendable (ChatSnapshot) -> Bool
) async -> ChatSnapshot? {
	await withTaskGroup(of: ChatSnapshot?.self) { group in
		group.addTask {
			for await snapshot in stream where matches(snapshot) {
				return snapshot
			}
			return nil
		}
		group.addTask {
			do {
				try await Task.sleep(for: limit)
			} catch is CancellationError {
				return nil
			} catch {
				fatalError("Task.sleep failed: \(error)")
			}
			return nil
		}
		let found = await group.next() ?? nil
		group.cancelAll()
		return found
	}
}

private func facts(_ settlement: Settlement, wallMs: Int64) -> TurnFacts {
	var facts = TurnFacts(turn: rateLimitedTurn, chat: .main, origin: phone)
	facts.fragments.append(
		Fragment(
			ulid: fixedUlid(40), hlc: HybridLogicalClock(wallMs: 1, logical: 0, deviceId: phone),
			civilDate: "1998-06-13", index: 0, draft: DraftID(), text: "How was my week?",
			slash: nil))
	facts.settlements.append(
		SettledAttempt(
			ulid: fixedUlid(41),
			hlc: HybridLogicalClock(wallMs: wallMs, logical: 0, deviceId: phone),
			civilDate: "1998-06-13", attempt: failedAttempt, settlement: settlement))
	return facts
}

private func milliseconds(_ date: Date) -> Int64 {
	Int64((date.timeIntervalSince1970 * 1000).rounded())
}

@Suite struct RetryWaitTests {
	let clock = HeldClock()
	let store = InMemoryRecordLog()

	func seedFailure(_ settlement: Settlement, at failedAt: Date) async throws {
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 1, ulid: fixedUlid(40),
					body: .synced(
						sampleUser(chatId: .main, text: "How was my week?", turn: rateLimitedTurn))),
				storedRecord(
					device: store.deviceId, wall: milliseconds(failedAt), ulid: fixedUlid(41),
					body: .synced(
						.turnSettled(
							TurnSettledBody(
								chatId: .main, turn: rateLimitedTurn, attempt: failedAttempt,
								settlement: settlement)))),
			])
	}

	@Test func tryAgainOpensOnlyWhenTheRateLimitWaitEnds() async throws {
		try await seedFailure(rateLimited(.seconds(7)), at: clock.now)
		let coach = makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		let waiting = await coach.currentSnapshot(.main)
		#expect(action(in: waiting) == .wait(thenTryAgain: rateLimitedTurn))
		try await clock.waitUntilHeld(.seconds(7))
		let stream = await coach.observe(.main)
		clock.release(.seconds(7))
		let opened = await first(in: stream, within: .seconds(2)) {
			action(in: $0) == .tryAgain(rateLimitedTurn)
		}
		#expect(opened != nil, "no snapshot opened Try again when the wait ended")
		#expect(clock.held.isEmpty)
	}

	@Test func aClaimDropsTheWaitAndANewRateLimitWaitsItsOwnHint() async throws {
		try await seedFailure(rateLimited(.seconds(7)), at: clock.now)
		let transport = FakeModelTransport()
		transport.script = Array(
			repeating: .fail(.http(status: 429, headers: ["retry-after": "3"])), count: 4)
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		_ = await coach.currentSnapshot(.main)
		try await clock.waitUntilHeld(.seconds(7))
		try await coach.retry(rateLimitedTurn, in: .main)
		try await clock.waitUntilHeld(.seconds(3))
		#expect(!clock.held.contains(.seconds(7)), "the old wait outlived the claim")
		let deadline = ContinuousClock.now + .seconds(5)
		while transport.requestCount < 4, ContinuousClock.now < deadline {
			clock.release(.seconds(3))
			try await Task.sleep(for: .milliseconds(5))
		}
		try await clock.waitUntilHeld(.seconds(3))
		#expect(clock.held == [.seconds(3)])
		let failedAgain = try #require(
			await coach.settledState(of: rateLimitedTurn, in: .main, within: .seconds(2)))
		guard case .failed(let failed) = failedAgain else {
			Issue.record("expected a second rate-limit failure, got \(failedAgain)")
			return
		}
		#expect(failed.notice.action == .wait(thenTryAgain: rateLimitedTurn))
		let stream = await coach.observe(.main)
		clock.release(.seconds(3))
		let opened = await first(in: stream, within: .seconds(2)) {
			action(in: $0) == .tryAgain(rateLimitedTurn)
		}
		#expect(opened != nil)
	}

	@Test func aWaitThatEndedBeforeTheChatOpenedOffersTryAgainAtOnce() async throws {
		try await seedFailure(rateLimited(.seconds(7)), at: clock.now.addingTimeInterval(-10))
		let coach = makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		#expect(action(in: await coach.currentSnapshot(.main)) == .tryAgain(rateLimitedTurn))
		#expect(clock.held.isEmpty)
	}

	@Test func aClockSetBackKeepsTheHlcAheadButNotTheWait() {
		let realNow = Date(timeIntervalSince1970: 1_790_000_000)
		let before = HybridLogicalClock.tick(
			now: realNow.addingTimeInterval(3_600), deviceId: phone, last: nil)
		let settledHlc = HybridLogicalClock.tick(now: realNow, deviceId: phone, last: before)
		#expect(settledHlc.wallTime == realNow.addingTimeInterval(3_600))
		let wait = RetryWaits.wait(
			of: facts(rateLimited(.seconds(7)), wallMs: settledHlc.wallMs), now: realNow)
		#expect(wait?.attempt == failedAttempt)
		#expect(wait?.remaining == .seconds(7))
	}

	@Test func aWaitStartedEarlierKeepsOnlyWhatIsLeft() {
		let now = Date(timeIntervalSince1970: 1_790_000_000)
		let started = milliseconds(now.addingTimeInterval(-3))
		#expect(
			RetryWaits.wait(of: facts(rateLimited(.seconds(7)), wallMs: started), now: now)?
				.remaining == .seconds(4))
		#expect(
			RetryWaits.wait(of: facts(rateLimited(nil), wallMs: started), now: now)?.remaining
				== .seconds(57))
	}

	@Test func onlyARateLimitThatCanBeTriedAgainWaits() {
		let now = Date(timeIntervalSince1970: 1_790_000_000)
		let wall = milliseconds(now)
		let saved = WriteSummary(
			memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		#expect(
			RetryWaits.wait(
				of: facts(
					.failed(.model(.rateLimited(retryAfter: .seconds(7))), saved: saved),
					wallMs: wall),
				now: now) == nil)
		#expect(
			RetryWaits.wait(
				of: facts(.failed(.model(.providerDown(.network)), saved: .none), wallMs: wall),
				now: now) == nil)
		var claimed = facts(rateLimited(.seconds(7)), wallMs: wall)
		claimed.claims.append(
			TurnClaimBody(
				chatId: .main, turn: rateLimitedTurn, attempt: AttemptID(ulid: fixedUlid(42))))
		#expect(RetryWaits.wait(of: claimed, now: now) == nil)
	}
}
