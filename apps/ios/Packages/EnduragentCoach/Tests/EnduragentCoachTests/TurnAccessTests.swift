import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test func missingKeySettlesNotConfiguredWithoutARequest() async throws {
		let coach = makeCoach(secrets: ICloudKeychainStore(backing: FixtureSecretStoreBacking()))
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
		let coach = makeCoach(secrets: secrets)
		let settled = try await coach.sendAndSettle("Hello")
		#expect(failure(settled) == .model(.accessUnavailable(.secureStorageLocked)))
		#expect(transport.requestCount == 0)
	}

	@Test func keyStoredAfterLaunchReachesTheNextAttempt() async throws {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		let coach = makeCoach(secrets: secrets)
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
