import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct CredentialRecoveryTests {
	@Test(arguments: [false, true])
	func migrationPrefersAnInterruptedRecoveryUndoRecord(afterTokenWrite: Bool) async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let previous = CreditsAccount(appAccountToken: oldToken, key: "test-old-credits-key")
		let current = CreditsAccount(
			appAccountToken: afterTokenWrite ? newToken : oldToken, key: "test-new-credits-key")
		let memory = try legacyCreditsBacking(previous: previous, current: current)
		let store = ICloudKeychainStore(backing: memory)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: true))
		#expect(try store.creditsAccount() == previous)
		#expect(try ICloudKeychainStore(backing: memory).creditsAccount() == previous)
		for account in ["intervalsConnectionStaging", "openRouterKey", "appAccountToken"] {
			#expect(try memory.copy(account: account) == nil)
		}
	}

	@Test func transientMigrationReadKeepsTheUndoRecord() async throws {
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let previous = CreditsAccount(appAccountToken: token, key: "test-old-credits-key")
		let current = CreditsAccount(appAccountToken: token, key: "test-new-credits-key")
		let memory = try legacyCreditsBacking(previous: previous, current: current)
		let undo = try memory.copy(account: "intervalsConnectionStaging")
		let store = ICloudKeychainStore(backing: OnceFailingStagingBacking(base: memory))
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await coach.creditsIdentity()
		}
		#expect(try memory.copy(account: "intervalsConnectionStaging") == undo)
		#expect(try memory.copy(account: CredentialSlot.creditsAccount.rawValue) == nil)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: true))
		#expect(try store.creditsAccount() == previous)
		#expect(try memory.copy(account: "intervalsConnectionStaging") == nil)
	}

	@Test func migrationRestoresMissingPreviousKey() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let previous = CreditsAccount(appAccountToken: oldToken, key: nil)
		let current = CreditsAccount(appAccountToken: newToken, key: "test-new-credits-key")
		let memory = try legacyCreditsBacking(previous: previous, current: current)
		let store = ICloudKeychainStore(backing: memory)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: false))
		#expect(try store.creditsAccount() == previous)
		#expect(try memory.copy(account: "intervalsConnectionStaging") == nil)
	}

	@Test func blockedMigrationPreservesUndoRecordAndRetriesAfterUnlock() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let previous = CreditsAccount(appAccountToken: oldToken, key: "test-old-credits-key")
		let current = CreditsAccount(appAccountToken: newToken, key: "test-new-credits-key")
		let memory = try legacyCreditsBacking(previous: previous, current: current)
		let undo = try memory.copy(account: "intervalsConnectionStaging")
		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: errSecInteractionNotAllowed)
		let store = ICloudKeychainStore(backing: memory)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		await #expect(throws: AccessUnavailable.secureStorageLocked) {
			try await coach.creditsIdentity()
		}
		#expect(try memory.copy(account: "intervalsConnectionStaging") == undo)
		#expect(try memory.copy(account: CredentialSlot.creditsAccount.rawValue) == nil)
		#expect(coach.diagnostics.entries.isEmpty)

		memory.failWrites(CredentialSlot.creditsAccount.rawValue, with: nil)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: oldToken, hasCreditsKey: true))
		#expect(try store.creditsAccount() == previous)
		#expect(try memory.copy(account: "intervalsConnectionStaging") == nil)
	}

	@Test(arguments: [false, true])
	func legacyIntervalsStageIsDiscardedWhenCreditsMigrate(wrapped: Bool) async throws {
		let encoded = try JSONEncoder().encode(StoredIntervalsConnection(testConnection))
		let connection = try #require(String(data: encoded, encoding: .utf8))
		let legacy = wrapped ? Data("{\"intervals\":{\"_0\":\(connection)}}".utf8) : encoded
		let memory = MemorySecretStoreBacking(items: [
			"intervalsConnectionStaging": legacy,
			"appAccountToken": Data(UUID().uuidString.utf8),
		])
		let store = ICloudKeychainStore(backing: memory)
		try store.storeIntervalsConnection(testConnection)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)

		let identity = try await coach.creditsIdentity()

		#expect(!identity.hasCreditsKey)
		#expect(try store.creditsAccount()?.appAccountToken == identity.appAccountToken)
		#expect(try store.intervalsConnection() == testConnection)
		#expect(try memory.copy(account: "intervalsConnectionStaging") == nil)
	}
}

extension CreditsClientTests {
	@Test(arguments: 0...4)
	func crashDuringRecoveryThenPeerIntervalsReplaceLeavesAWholePair(_ writes: Int) async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let oldKey = "test-old-credits-key"
		let newKey = "test-new-credits-key"
		let memory = MemorySecretStoreBacking()
		let deviceB = ICloudKeychainStore(backing: memory)
		try deviceB.storeCreditsAccount(CreditsAccount(appAccountToken: oldToken, key: oldKey))
		try deviceB.storeIntervalsConnection(testConnection)
		let coachB = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: deviceB)
		#expect(await coachB.status().setup == .ready)
		let interrupted = InterruptedSecretStoreBacking(base: memory)
		let deviceA = ICloudKeychainStore(backing: interrupted)
		let client = try makeClient(secrets: deviceA)
		_ = try await CreditsURLStub.withHandler({ _ in
			.json(200, #"{"data":{"limit_remaining":1}}"#)
		}) {
			try await client.balance(scale: CreditScale(creditsPerUsd: 100))
		}
		interrupted.stop(after: writes)
		do {
			_ = try await CreditsURLStub.withHandler({ _ in
				.json(
					200,
					#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"test-new-credits-key","credits":150}"#
				)
			}) {
				try await client.recover(signedTransaction: "header.payload.signature")
			}
		} catch let error as AccessUnavailable {
			#expect(error == .secureStorageUnavailable)
		}
		guard
			case .replaced = await coachB.changeTraining(
				.replace(apiKey: "icu-rotated-key", athlete: .keyOwner))
		else {
			Issue.record("expected the peer intervals replacement to succeed")
			return
		}
		interrupted.resume()
		let coachA = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: deviceA)
		for (coach, store) in [(coachA, deviceA), (coachB, deviceB)] {
			let identity = try await coach.creditsIdentity()
			let key = try store.creditsAccount()?.key
			#expect(identity.hasCreditsKey)
			#expect(
				(key == oldKey && identity.appAccountToken == oldToken)
					|| (key == newKey && identity.appAccountToken == newToken),
				"after \(writes) writes: key=\(key ?? "nil"), token=\(identity.appAccountToken)")
		}
	}

	@Test func successfulRecoveryCommitsBothValues() async throws {
		let oldToken = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		let newToken = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
		let memory = MemorySecretStoreBacking()
		let original = ICloudKeychainStore(backing: memory)
		try original.storeCreditsAccount(
			CreditsAccount(appAccountToken: oldToken, key: "test-old-credits-key"))
		let client = try makeClient(secrets: original)

		_ = try await CreditsURLStub.withHandler({ _ in
			.json(
				200,
				#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"test-new-credits-key","credits":150}"#
			)
		}) {
			try await client.recover(signedTransaction: "test.signed.transaction")
		}

		let restarted = ICloudKeychainStore(backing: memory)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: restarted)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: newToken, hasCreditsKey: true))
		#expect(
			try restarted.creditsAccount()
				== CreditsAccount(appAccountToken: newToken, key: "test-new-credits-key"))
	}
}

func legacyCreditsBacking(previous: CreditsAccount, current: CreditsAccount) throws
	-> MemorySecretStoreBacking
{
	var undo = ["previousAppAccountToken": previous.appAccountToken.uuidString]
	undo["previousKey"] = previous.key
	var items = [
		"intervalsConnectionStaging": try JSONEncoder().encode(["credits": undo]),
		"appAccountToken": Data(current.appAccountToken.uuidString.utf8),
	]
	items["openRouterKey"] = current.key.map { Data($0.utf8) }
	return MemorySecretStoreBacking(items: items)
}

private final class OnceFailingStagingBacking: SecretStoreBacking, @unchecked Sendable {
	private let base: MemorySecretStoreBacking
	private let lock = NSLock()
	private var failed = false

	init(base: MemorySecretStoreBacking) {
		self.base = base
	}

	func add(account: String, data: Data) throws { try base.add(account: account, data: data) }

	func copy(account: String) throws -> Data? {
		let failNow = lock.withLock {
			guard account == "intervalsConnectionStaging", !failed else { return false }
			failed = true
			return true
		}
		if failNow { throw KeychainStoreError(status: errSecNotAvailable) }
		return try base.copy(account: account)
	}

	func update(account: String, data: Data) throws {
		try base.update(account: account, data: data)
	}

	func delete(account: String) throws { try base.delete(account: account) }
}
