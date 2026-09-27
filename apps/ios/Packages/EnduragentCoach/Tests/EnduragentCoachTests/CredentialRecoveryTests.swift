import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct CredentialRecoveryTests {
	@Test(arguments: RecoveryCrashPoint.allCases)
	func restartRollsBackPartialRecovery(_ crashPoint: RecoveryCrashPoint) async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let oldKey = "test-old-credits-key"
		let newKey = "test-new-credits-key"
		let memory = MemorySecretStoreBacking()
		let original = ICloudKeychainStore(backing: memory)
		try original.storeAppAccountToken(oldToken)
		try original.storeOpenRouterKey(oldKey)
		try original.stageReplacement(
			.credits(previousKey: oldKey, previousAppAccountToken: oldToken))
		try original.storeOpenRouterKey(newKey)
		if crashPoint == .afterTokenWrite {
			try original.storeAppAccountToken(newToken)
		}

		let restarted = ICloudKeychainStore(backing: memory)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: restarted)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: true))
		#expect(try restarted.openRouterKey() == oldKey)
		#expect(try restarted.appAccountToken() == oldToken)
		#expect(try restarted.stagedReplacement() == nil)
	}

	@Test func successfulRecoveryCommitsBothValues() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let memory = MemorySecretStoreBacking()
		let original = ICloudKeychainStore(backing: memory)
		try original.storeAppAccountToken(oldToken)
		try original.storeOpenRouterKey("test-old-credits-key")

		try await testVault(original).storeRecovery(
			key: try #require(NonEmptySecret("test-new-credits-key")),
			appAccountToken: newToken)

		let restarted = ICloudKeychainStore(backing: memory)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: restarted)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: newToken, hasCreditsKey: true))
		#expect(try restarted.openRouterKey() == "test-new-credits-key")
		#expect(try restarted.stagedReplacement() == nil)
	}

	@Test func restartRestoresMissingPreviousKey() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let memory = MemorySecretStoreBacking()
		let original = ICloudKeychainStore(backing: memory)
		try original.storeAppAccountToken(oldToken)
		try original.stageReplacement(
			.credits(previousKey: nil, previousAppAccountToken: oldToken))
		try original.storeOpenRouterKey("test-new-credits-key")
		try original.storeAppAccountToken(newToken)

		let restarted = ICloudKeychainStore(backing: memory)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: restarted)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: false))
		#expect(try restarted.openRouterKey() == nil)
		#expect(try restarted.stagedReplacement() == nil)
	}

	@Test func blockedRollbackKeepsPreviousPairAndRetriesAfterUnlock() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let oldKey = "test-old-credits-key"
		let memory = MemorySecretStoreBacking()
		let store = ICloudKeychainStore(backing: memory)
		try store.storeAppAccountToken(oldToken)
		try store.storeOpenRouterKey(oldKey)
		try store.stageReplacement(
			.credits(previousKey: oldKey, previousAppAccountToken: oldToken))
		try store.storeOpenRouterKey("test-new-credits-key")
		try store.storeAppAccountToken(newToken)
		memory.failWrites(CredentialSlot.creditsKey.rawValue, with: errSecInteractionNotAllowed)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: true))
		#expect(try store.openRouterKey() == oldKey)
		#expect(try store.appAccountToken() == oldToken)
		#expect(
			try store.stagedReplacement()
				== .credits(previousKey: oldKey, previousAppAccountToken: oldToken))

		memory.failWrites(CredentialSlot.creditsKey.rawValue, with: nil)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: true))
		#expect(try store.openRouterKey() == oldKey)
		#expect(try store.appAccountToken() == oldToken)
		#expect(try store.stagedReplacement() == nil)
	}

	@Test func legacyIntervalsStageDecodesAndIsDiscardedOnRestart() async throws {
		let legacy = try JSONEncoder().encode(StoredIntervalsConnection(testConnection))
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.intervalsConnectionStaging.rawValue: legacy
		])
		let store = ICloudKeychainStore(backing: memory)
		#expect(try store.stagedReplacement() == .intervals(testConnection))

		_ = try await testVault(store).trainingConnection()

		#expect(try store.stagedReplacement() == nil)
	}
}

enum RecoveryCrashPoint: CaseIterable, Sendable {
	case afterKeyWrite
	case afterTokenWrite
}
