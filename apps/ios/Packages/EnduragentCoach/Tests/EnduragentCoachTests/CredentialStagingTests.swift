import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test(arguments: [Data(#"{"future":{"x":1}}"#.utf8), Data([0xFF, 0xFE, 0xFD])])
	func undecodableLegacyStagingDoesNotBlockCredits(_ unreadable: Data) async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let memory = MemorySecretStoreBacking(items: [
			"intervalsConnectionStaging": unreadable,
			"openRouterKey": Data("test-credits-key".utf8),
			"appAccountToken": Data(token.uuidString.utf8),
		])
		let secrets = ICloudKeychainStore(backing: memory)
		let coach = coach(secrets)

		#expect(await coach.status().setup == .ready)
		await coach.lifecycle(.becameActive)
		#expect(await coach.status().setup == .ready)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(
			try secrets.creditsAccount()
				== CreditsAccount(appAccountToken: token, key: "test-credits-key"))
		#expect(try memory.copy(account: "intervalsConnectionStaging") == nil)
		#expect(coach.diagnostics.entries.isEmpty)
	}

	@Test func existingAccountDoesNotReadLaterUnreadableLegacyStaging() async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let memory = MemorySecretStoreBacking()
		let secrets = ICloudKeychainStore(backing: memory)
		let account = CreditsAccount(appAccountToken: token, key: "test-credits-key")
		try secrets.storeCreditsAccount(account)
		let coach = coach(secrets)
		#expect(await coach.status().setup == .ready)
		let unreadable = Data(#"{"future":{"x":1}}"#.utf8)
		try memory.add(account: "intervalsConnectionStaging", data: unreadable)
		memory.fail("intervalsConnectionStaging", with: errSecDecode)
		let reads = memory.readCount

		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(memory.readCount - reads == 1)
		#expect(try ICloudKeychainStore(backing: memory).creditsAccount() == account)
		memory.fail("intervalsConnectionStaging", with: nil)
		#expect(try memory.copy(account: "intervalsConnectionStaging") == unreadable)
	}

	@Test func malformedLegacyKeyDoesNotDiscardADecodableUndoRecord() async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: token, key: "test-old-credits-key")
		let current = CreditsAccount(appAccountToken: token, key: "test-new-credits-key")
		let memory = try legacyCreditsBacking(previous: previous, current: current)
		try memory.update(account: "openRouterKey", data: Data([0xFF]))
		let secrets = ICloudKeychainStore(backing: memory)
		let coach = coach(secrets)

		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(try secrets.creditsAccount() == previous)
		#expect(try memory.copy(account: "intervalsConnectionStaging") == nil)
		#expect(try memory.copy(account: "openRouterKey") == nil)
	}

	@Test(arguments: ["intervalsConnectionStaging", "openRouterKey", "appAccountToken"])
	func failedLegacyDeletionKeepsCombinedAccountAuthoritative(_ failedSlot: String) async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: token, key: "test-old-credits-key")
		let current = CreditsAccount(appAccountToken: token, key: "test-new-credits-key")
		let memory = try legacyCreditsBacking(previous: previous, current: current)
		let backing = FailedLegacyDeletionBacking(base: memory, failedSlot: failedSlot)
		let secrets = ICloudKeychainStore(backing: backing)
		let coach = coach(secrets)

		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await coach.creditsIdentity()
		}
		#expect(try memory.copy(account: failedSlot) != nil)
		for slot in ["intervalsConnectionStaging", "openRouterKey", "appAccountToken"] {
			memory.fail(slot, with: errSecDecode)
		}
		let reads = memory.readCount
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(memory.readCount - reads == 1)
		#expect(try ICloudKeychainStore(backing: backing).creditsAccount() == previous)
	}
}

private struct FailedLegacyDeletionBacking: SecretStoreBacking {
	let base: MemorySecretStoreBacking
	let failedSlot: String

	func add(account: String, data: Data) throws { try base.add(account: account, data: data) }

	func copy(account: String) throws -> Data? { try base.copy(account: account) }

	func update(account: String, data: Data) throws {
		try base.update(account: account, data: data)
	}

	func delete(account: String) throws {
		if account == failedSlot { throw KeychainStoreError(status: errSecNotAvailable) }
		try base.delete(account: account)
	}
}
