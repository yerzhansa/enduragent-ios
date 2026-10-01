import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test func missingKeySettlesNotConfiguredWithoutARequest() async throws {
		let coach = await makeCoach(
			secrets: ICloudKeychainStore(backing: FixtureSecretStoreBacking()))
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(failure(settled) == .model(.accessUnavailable(.notConfigured(.credits))))
		#expect(!settled.retryable)
		#expect(transport.requestCount == 0)
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn))
		#expect(claims.records.count == 1)
	}

	@Test func lockedKeychainSettlesSecureStorageLocked() async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		backing.locked = true
		let coach = await makeCoach(secrets: secrets)
		let settled = try await coach.sendAndSettle("Hello")
		#expect(failure(settled) == .model(.accessUnavailable(.secureStorageLocked)))
		#expect(transport.requestCount == 0)
	}

	@Test func keyStoredAfterLaunchReachesTheNextAttempt() async throws {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		let coach = await makeCoach(secrets: secrets)
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		try secrets.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: UUID(),
				key: "sk-or-stored-after-launch"))
		transport.respond = ScriptedReply.sequence(
			[.text("Hello, Ada."), .finish(reason: .stop)], otherwise: transport.respond
		)
		try await coach.retry(turn, in: .main)
		let answered = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(answered) == "Hello, Ada.")
		#expect(transport.requests.count == 1)
		let request = try #require(transport.requests.first)
		#expect(
			request.credential
				== ProviderCredential(secret: "sk-or-stored-after-launch", method: .credits))
		#expect(request.model == testModel)
		#expect(request.charge == .chatAttempt)
	}

}

@Suite struct TurnAccessTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test(arguments: [AccessMethod.credits, .openRouterAccount])
	func modelWorkRequiresProviderConsent(method: AccessMethod) async throws {
		try await seedHistory(
			store, clock: clock, turns: 3, tokens: historyBudget(clock: clock) * 6 / 5)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], otherwise: transport.respond)
		transport.respond = ScriptedReply.sequence(
			[.text("Earlier training."), .finish(reason: .stop)], for: .summary,
			otherwise: transport.respond)
		let secrets = keyedSecrets()
		if method == .openRouterAccount {
			try secrets.storeOpenRouterAccountKey("sk-or-test-account")
			try secrets.storeAccessSelection(.openRouterAccount(model: testModel))
		}
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, secrets: secrets, consent: false)
		#expect(try await coach.observedStatus().needsProviderConsent)
		let settled = try await coach.sendAndSettle("Is Thursday on?")
		#expect(failure(settled) == .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		#expect(
			await coach.startNewConversation(in: .main)
				== .started(memory: .providerConsentRequired))
		#expect(transport.requestCount == 0)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records.isEmpty
		)
		try await coach.recordConsent()
		#expect(try await coach.observedStatus().needsProviderConsent == false)
		let reply = try await coach.sendAndSettle("Is Thursday on?")
		#expect(replyText(reply) == "Thursday is on.")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		#expect(sent(.chatAttempt, by: transport).map(\.credential.method) == [method])
		#expect(!sent(.memoryFlush, by: transport).isEmpty)
	}

	@Test func pendingMemorySaveRequiresProviderConsent() async throws {
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
								chatId: .main,
								messageUlids: history.flatMap { [$0.user, $0.reply] }))))
			])
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, consent: false)
		await coach.lifecycle(.becameActive)
		let refused = try await coach.sendAndSettle("Is Thursday on?")
		#expect(failure(refused) == .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushSettled]))).records.isEmpty
		)
		try await coach.recordConsent()
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday is on."), .finish(reason: .stop)], otherwise: transport.respond)
		#expect(replyText(try await coach.sendAndSettle("Is Thursday on?")) == "Thursday is on.")
		try await waitForRecords(.deviceLocal([.flushSettled]), count: 1, in: store)
		#expect(sent(.memoryFlush, by: transport).count == 1)
		let extracted = try #require(sent(.memoryFlush, by: transport).first)
		#expect(extracted.messages.contains { $0.unstampedContent == "Question 0" })

	}
}
