import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test func unverifiableReplacementCannotExecuteOldWorkoutReview() async throws {
		let secrets = keyedSecrets()
		let coach = coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = await coach.changeTraining(.replace(apiKey: "icu-offline", athlete: .keyOwner))
		#expect(try secrets.intervalsConnection()?.resolvedAthlete == nil)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.currentSnapshot(.main)?.review?.notice?.kind == .accountChanged)
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(.accountChanged))
		#expect(
			!offline.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}

	@Test func blockedMigrationIsNotOverwrittenByATrainingReplacement() async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: token, key: "test-old-credits-key")
		let memory = legacyCreditsBacking(previous)
		let store = ICloudKeychainStore(backing: memory)
		try store.storeIntervalsConnection(testConnection)
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: errSecNotAvailable)
		let coach = coach(store)
		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await coach.creditsIdentity()
		}

		let outcome = await coach.changeTraining(
			.replace(apiKey: "icu-rotated-key", athlete: .keyOwner))

		guard case .replaced = outcome else {
			Issue.record("expected replacement during blocked migration, got \(outcome)")
			return
		}
		#expect(try store.intervalsConnection()?.credential == .apiKey("icu-rotated-key"))
		#expect(try memory.copy(account: "openRouterKey") == Data("test-old-credits-key".utf8))
		#expect(memory.writes(to: "openRouterKey") == 0)
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: nil)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(try store.creditsAccount() == previous)
	}
}

extension CreditsClientTests {
	@Test func blockedMigrationIsNotUndoneByAGrant() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: oldToken, key: "test-old-credits-key")
		let memory = legacyCreditsBacking(previous)
		let store = ICloudKeychainStore(backing: memory)
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: errSecNotAvailable)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await coach.creditsIdentity()
		}
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: nil)
		let client = try makeClient(secrets: store)

		_ = try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"kind":"grantMinted","key":"test-granted-credits-key","credits":200}"#)
		}) {
			try await client.grant(deviceCheck: Data([0x01]))
		}

		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: true))
		#expect(
			try store.creditsAccount()
				== CreditsAccount(appAccountToken: oldToken, key: "test-granted-credits-key"))
		#expect(try memory.copy(account: "openRouterKey") == nil)
	}

	@Test func failedRecoveryKeepsThePreviousAccountDuringTheNextReplacement() async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: token, key: "test-old-credits-key")
		let memory = FixtureSecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		try secrets.storeCreditsAccount(previous)
		try secrets.storeIntervalsConnection(testConnection)
		let client = try makeClient(secrets: secrets)
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: errSecNotAvailable)

		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await CreditsURLStub.withHandler({ _ in
				.json(
					200,
					#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"test-new-credits-key","credits":150}"#
				)
			}) {
				try await client.recover(signedTransaction: "test.signed.transaction")
			}
		}

		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: nil)
		let fixture = CredentialVaultTests()
		let coach = fixture.coach(secrets)
		let outcome = await coach.changeTraining(
			.replace(apiKey: "icu-rotated-key", athlete: .keyOwner))
		guard case .replaced = outcome else {
			Issue.record("expected replacement after failed recovery, got \(outcome)")
			return
		}
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(try secrets.creditsAccount() == previous)
		#expect(try secrets.intervalsConnection()?.credential == .apiKey("icu-rotated-key"))
	}
}
