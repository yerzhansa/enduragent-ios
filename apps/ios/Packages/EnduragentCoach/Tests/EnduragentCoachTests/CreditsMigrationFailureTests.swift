import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test(arguments: ["openRouterKey", "appAccountToken"])
	func failedLegacyDeletionKeepsCombinedAccountAuthoritative(_ failedSlot: String) async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: token, key: "test-old-credits-key")
		let memory = legacyCreditsBacking(previous)
		let backing = FailedLegacyDeletionBacking(base: memory, failedSlot: failedSlot)
		let secrets = ICloudKeychainStore(backing: backing)
		let coach = coach(secrets)

		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await coach.creditsIdentity()
		}
		#expect(try memory.copy(account: failedSlot) != nil)
		for slot in ["openRouterKey", "appAccountToken"] {
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
	let base: FixtureSecretStoreBacking
	let failedSlot: String

	func add(account: String, data: Data) throws { try base.add(account: account, data: data) }

	func copy(account: String) throws -> Data? { try base.copy(account: account) }

	func update(account: String, data: Data) throws {
		try base.update(account: account, data: data)
	}

	func delete(account: String) throws {
		if account == failedSlot { throw KeychainStoreError.keychain(errSecNotAvailable) }
		try base.delete(account: account)
	}
}
