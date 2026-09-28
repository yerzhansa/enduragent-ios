import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test(arguments: [Data(#"{"future":{"x":1}}"#.utf8), Data([0xFF, 0xFE, 0xFD])])
	func undecodableStagingDoesNotBlockCredits(_ unreadable: Data) async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.intervalsConnectionStaging.rawValue: unreadable
		])
		let secrets = ICloudKeychainStore(backing: memory)
		try secrets.storeOpenRouterKey("test-credits-key")
		try secrets.storeAppAccountToken(token)
		let coach = coach(secrets)
		#expect(await coach.status().setup == .ready)
		await coach.lifecycle(.becameActive)
		#expect(await coach.status().setup == .ready)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(try secrets.openRouterKey() == "test-credits-key")
		#expect(try memory.copy(account: CredentialSlot.intervalsConnectionStaging.rawValue) == nil)
		#expect(
			coach.diagnostics.entries.contains {
				if case .secureStorageFailed(.intervalsConnectionStaging, _) = $0.event {
					return true
				}
				return false
			})
	}

	@Test(arguments: [CredentialSlot.creditsKey, .appAccountToken])
	func unreadableStagingAfterLaunchDoesNotBlockCreditsReads(_ slot: CredentialSlot) async throws {
		let memory = MemorySecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let token = try secrets.appAccountToken()
		try secrets.storeOpenRouterKey("test-credits-key")
		let vault = vault(secrets)
		#expect(await vault.setup(builtInModel: testModel) == .ready)
		try memory.add(
			account: CredentialSlot.intervalsConnectionStaging.rawValue,
			data: Data(#"{"future":{"x":1}}"#.utf8))
		if slot == .creditsKey {
			#expect(try await vault.creditsKey()?.value == "test-credits-key")
		} else {
			#expect(try await vault.appAccountToken() == token)
		}
		#expect(try memory.copy(account: CredentialSlot.intervalsConnectionStaging.rawValue) == nil)
	}

	@Test func malformedLiveKeyDoesNotDiscardADecodableUndoRecord() async throws {
		let memory = MemorySecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let token = try secrets.appAccountToken()
		let undo = CredentialReplacement.credits(
			previousKey: "test-old-credits-key", previousAppAccountToken: token)
		try secrets.stageReplacement(undo)
		try memory.add(account: CredentialSlot.creditsKey.rawValue, data: Data([0xFF]))
		let vault = vault(secrets)
		#expect(await vault.setup(builtInModel: testModel) == .ready)
		#expect(try secrets.stagedReplacement() == undo)
		try secrets.storeOpenRouterKey("test-new-credits-key")
		#expect(await vault.setup(builtInModel: testModel) == .ready)
		#expect(try secrets.openRouterKey() == "test-old-credits-key")
		#expect(try secrets.stagedReplacement() == nil)
	}
}
