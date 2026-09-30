import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct CreditsAccountMigrationTests {
	@Test func migrationReadsLegacyKeyAndTokenOnceThenDeletesThem() async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let key = "test-legacy-credits-key"
		let memory = MemorySecretStoreBacking(items: [
			"openRouterKey": Data(key.utf8),
			"appAccountToken": Data(token.uuidString.utf8),
			"intervalsConnectionStaging": Data("undecodable legacy staging".utf8),
		])
		let store = ICloudKeychainStore(backing: memory)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		let identity = try await coach.creditsIdentity()

		#expect(identity == CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(try store.creditsAccount() == CreditsAccount(appAccountToken: token, key: key))
		let legacyAccounts = ["intervalsConnectionStaging", "openRouterKey", "appAccountToken"]
		#expect(Set(memory.deletedAccounts) == Set(legacyAccounts))
		for legacy in legacyAccounts {
			#expect(memory.readAccounts.filter { $0 == legacy }.count == 1)
			#expect(try memory.copy(account: legacy) == nil)
			#expect(memory.writes(to: legacy) == 0)
			memory.fail(legacy, with: errSecNotAvailable)
		}
		let reads = memory.readCount
		let peer = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(),
			secrets: ICloudKeychainStore(backing: memory))
		#expect(try await peer.creditsIdentity() == identity)
		#expect(memory.readCount - reads == 1)
		#expect(memory.readAccounts.last == CredentialSlot.creditsAccount.rawValue)
		#expect(memory.writes(to: CredentialSlot.creditsAccount.rawValue) == 1)
	}

	@Test func tokenlessLegacyKeyWaitsForAccountPreparation() async throws {
		let memory = MemorySecretStoreBacking(items: ["openRouterKey": Data("test-legacy-key".utf8)]
		)
		let store = ICloudKeychainStore(backing: memory)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		#expect(await coach.status().setup == .needsAccessMethod)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(
					appAccountToken: nil, hasCreditsKey: false))
		#expect(memory.writeCount == 0)
		#expect(memory.deletedAccounts.isEmpty)
		#expect(try memory.copy(account: "openRouterKey") == Data("test-legacy-key".utf8))
		let token = try await coach.prepareCreditsPurchase()
		#expect(
			try store.creditsAccount()
				== CreditsAccount(
					appAccountToken: token, key: "test-legacy-key"))
		#expect(memory.writeCount == 1)
		#expect(try memory.copy(account: "openRouterKey") == nil)
		#expect(await coach.status().setup == .ready)
	}

	@Test func purchasePreparationMintsOnlyWhenRequested() async throws {
		let memory = MemorySecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(
					appAccountToken: nil, hasCreditsKey: false))
		#expect(memory.writeCount == 0)
		let token = try await coach.prepareCreditsPurchase()
		#expect(try await coach.prepareCreditsPurchase() == token)
		#expect(try store.creditsAccount() == CreditsAccount(appAccountToken: token, key: nil))
		#expect(memory.writeCount == 1)
		#expect(memory.deletedAccounts.isEmpty)
	}

	@Test func concurrentInitializationOnTwoDevicesConvergesOnOneAccount() async throws {
		let memory = MemorySecretStoreBacking()
		let interleaved = PeerInitializationBeforeAddBacking(base: memory)
		let firstStore = ICloudKeychainStore(backing: interleaved)
		let secondStore = ICloudKeychainStore(backing: memory)
		let first = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: firstStore)
		let second = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: secondStore)

		let firstToken = try await first.prepareCreditsPurchase()
		let secondToken = try await second.prepareCreditsPurchase()

		#expect(firstToken == secondToken)
		let losingAccount = try #require(interleaved.attemptedAccount)
		#expect(losingAccount.appAccountToken != firstToken)
		#expect(interleaved.duplicateAdds == 1)
		#expect(memory.writes(to: CredentialSlot.creditsAccount.rawValue) == 1)
		let expected = CreditsAccount(
			appAccountToken: firstToken, key: nil)
		#expect(try firstStore.creditsAccount() == expected)
		#expect(try secondStore.creditsAccount() == expected)
		#expect(try memory.copy(account: "openRouterKey") == nil)
		#expect(try memory.copy(account: "appAccountToken") == nil)
	}

	@Test func creditsIdentityReadsTheCombinedAccountOnce() async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.creditsAccount.rawValue: try JSONEncoder().encode(
				CreditsAccount(appAccountToken: token, key: "test-credits-key"))
		])
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(),
			secrets: ICloudKeychainStore(backing: memory))

		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(memory.readAccounts == [CredentialSlot.creditsAccount.rawValue])
	}

	#if DEBUG
		@Test func replacingAppAccountTokenKeepsTheCreditsKey() async throws {
			let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
			let memory = MemorySecretStoreBacking(items: [
				CredentialSlot.creditsAccount.rawValue: try JSONEncoder().encode(
					CreditsAccount(appAccountToken: token, key: "test-credits-key"))
			])
			let store = ICloudKeychainStore(backing: memory)
			let coach = await makeCoach(
				transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

			try await coach.replaceAppAccountToken()

			let identity = try await coach.creditsIdentity()
			#expect(identity.appAccountToken != token)
			#expect(identity.hasCreditsKey)
			#expect(
				try store.creditsAccount()
					== CreditsAccount(
						appAccountToken: try #require(identity.appAccountToken),
						key: "test-credits-key"))
			#expect(memory.writes(to: CredentialSlot.creditsAccount.rawValue) == 1)
			#expect(memory.writes(to: "openRouterKey") == 0)
			#expect(memory.writes(to: "appAccountToken") == 0)
		}
	#endif
}

private final class PeerInitializationBeforeAddBacking: SecretStoreBacking, @unchecked Sendable {
	private let base: MemorySecretStoreBacking
	private let lock = NSLock()
	private var attempted: CreditsAccount?
	private var duplicates = 0

	var attemptedAccount: CreditsAccount? { lock.withLock { attempted } }
	var duplicateAdds: Int { lock.withLock { duplicates } }

	init(base: MemorySecretStoreBacking) {
		self.base = base
	}

	func add(account: String, data: Data) throws {
		if account == CredentialSlot.creditsAccount.rawValue {
			let candidate = try JSONDecoder().decode(CreditsAccount.self, from: data)
			let firstAttempt = lock.withLock {
				guard attempted == nil else { return false }
				attempted = candidate
				return true
			}
			if firstAttempt { _ = try ICloudKeychainStore(backing: base).prepareCreditsAccount() }
		}
		do {
			try base.add(account: account, data: data)
		} catch let error as KeychainStoreError where error.status == errSecDuplicateItem {
			lock.withLock { duplicates += 1 }
			throw error
		}
	}

	func copy(account: String) throws -> Data? { try base.copy(account: account) }

	func update(account: String, data: Data) throws {
		try base.update(account: account, data: data)
	}

	func delete(account: String) throws { try base.delete(account: account) }
}
