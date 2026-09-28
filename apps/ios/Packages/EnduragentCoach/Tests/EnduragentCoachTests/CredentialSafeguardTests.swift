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

	@Test func blockedRollbackIsNotOverwrittenByATrainingReplacement() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let memory = MemorySecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		try store.storeAppAccountToken(oldToken)
		try store.storeOpenRouterKey("test-old-credits-key")
		try store.storeIntervalsConnection(testConnection)
		try store.stageReplacement(
			.credits(previousKey: "test-old-credits-key", previousAppAccountToken: oldToken))
		try store.storeOpenRouterKey("test-new-credits-key")
		memory.failWrites(CredentialSlot.creditsKey.rawValue, with: errSecNotAvailable)
		let coach = coach(store)
		_ = await coach.changeTraining(.replace(apiKey: "icu-rotated-key", athlete: .keyOwner))
		memory.failWrites(CredentialSlot.creditsKey.rawValue, with: nil)
		_ = await coach.status()
		#expect(try store.openRouterKey() == "test-old-credits-key")
		#expect(try store.appAccountToken() == oldToken)
	}

	@Test func blockedRollbackIsNotUndoneByAGrant() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let memory = MemorySecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		try store.storeAppAccountToken(oldToken)
		try store.storeOpenRouterKey("test-old-credits-key")
		try store.stageReplacement(
			.credits(previousKey: "test-old-credits-key", previousAppAccountToken: oldToken))
		try store.storeOpenRouterKey("test-new-credits-key")
		try store.storeAppAccountToken(newToken)
		memory.failWrites(CredentialSlot.creditsKey.rawValue, with: errSecNotAvailable)
		let vault = testVault(store)
		_ = await vault.setup(builtInModel: testModel)
		memory.failWrites(CredentialSlot.creditsKey.rawValue, with: nil)
		let granted = try #require(NonEmptySecret("test-granted-credits-key"))
		try await vault.storeCreditsKey(granted)
		_ = await vault.setup(builtInModel: testModel)
		#expect(try store.openRouterKey() == "test-granted-credits-key")
		#expect(try store.appAccountToken() == oldToken)
	}

	@Test func failedRecoveryIsRolledBackBeforeTheNextReplacement() async throws {
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let newKey = try #require(NonEmptySecret("test-new-credits-key"))
		let memory = MemorySecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let oldToken = try secrets.appAccountToken()
		try secrets.storeOpenRouterKey("test-old-credits-key")
		try secrets.storeIntervalsConnection(testConnection)
		let vault = vault(secrets)
		memory.failWrites(CredentialSlot.appAccountToken.rawValue, with: errSecNotAvailable)
		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await vault.storeRecovery(key: newKey, appAccountToken: newToken)
		}
		memory.failWrites(CredentialSlot.appAccountToken.rawValue, with: nil)
		_ = await vault.change(.replace(apiKey: "icu-rotated-key", athlete: .keyOwner)) { false }
		let pair = (try secrets.openRouterKey(), try secrets.appAccountToken())
		#expect(pair.0 == "test-old-credits-key", "\(pair)")
		#expect(pair.1 == oldToken, "\(pair)")
	}
}
