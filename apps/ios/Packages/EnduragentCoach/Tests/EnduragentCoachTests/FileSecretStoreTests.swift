import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct FileSecretStoreTests {
	@Test func fileFailureKeepsItsCodeWithoutErrorText() async throws {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer {
			do {
				try FileManager.default.removeItem(at: directory)
			} catch {
				Issue.record(error, "unwritable secrets directory cleanup")
			}
		}
		let store = try ICloudKeychainStore.fixture(directory: directory).store
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		try FileManager.default.createDirectory(
			at: directory.appending(path: FixtureSecretStoreBacking.fileName),
			withIntermediateDirectories: false)
		let expected: CocoaError
		do {
			_ = try store.prepareCreditsAccount()
			Issue.record("expected the file write to fail")
			return
		} catch let error as CocoaError {
			expected = error
		}
		await #expect(throws: AccessUnavailable.secureStorageUnavailable) {
			try await coach.prepareCreditsPurchase()
		}
		let entry = try #require(coach.diagnostics.entries.last)
		guard case .secureStorageFailed(.creditsAccount, .fileSystem(let code)) = entry.event else {
			Issue.record("expected the file system failure code")
			return
		}
		#expect(code == expected.code.rawValue)
	}

	@Test func directoryStorePersistsAcrossInstances() throws {
		try withTemporaryDirectory { directory in
			let first = try ICloudKeychainStore.fixture(directory: directory).store
			try first.storeCreditsAccount(
				CreditsAccount(
					appAccountToken: UUID(), key: "sk-or-test-0000")
			)
			try first.storeIntervalsConnection(testConnection)
			let token = try first.creditsAccount()?.appAccountToken
			let second = try ICloudKeychainStore.fixture(directory: directory).store
			#expect(try second.creditsAccount()?.key == "sk-or-test-0000")
			#expect(try second.intervalsConnection() == testConnection)
			#expect(try second.creditsAccount()?.appAccountToken == token)
		}
	}

	@Test func failedAccountPersistenceKeepsThePreviousCreditsPair() throws {
		try withTemporaryDirectory { directory in
			let store = try ICloudKeychainStore.fixture(directory: directory).store
			let previous = CreditsAccount(appAccountToken: UUID(), key: "test-old-credits-key")
			try store.storeCreditsAccount(previous)
			let file = directory.appending(path: FixtureSecretStoreBacking.fileName)
			try FileManager.default.removeItem(at: file)
			try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
			#expect(throws: CocoaError.self) {
				try store.storeCreditsAccount(
					CreditsAccount(appAccountToken: UUID(), key: "test-new-credits-key"))
			}
			#expect(try store.creditsAccount() == previous)
		}
	}

	@Test func fileBackingKeepsTheKeychainItemContract() throws {
		try withTemporaryDirectory { directory in
			let (_, backing) = try ICloudKeychainStore.fixture(directory: directory)
			let account = CredentialSlot.openRouterAccountKey.rawValue
			let original = Data("test-original-key".utf8)
			let replacement = Data("test-replacement-key".utf8)
			#expect(try backing.copy(account: account) == nil)
			#expect(throws: KeychainStoreError.keychain(errSecItemNotFound)) {
				try backing.update(account: account, data: replacement)
			}
			try backing.add(account: account, data: original)
			#expect(throws: KeychainStoreError.keychain(errSecDuplicateItem)) {
				try backing.add(account: account, data: replacement)
			}
			#expect(try backing.copy(account: account) == original)
			try backing.update(account: account, data: replacement)
			let reopened = try ICloudKeychainStore.fixture(directory: directory).store
			#expect(try reopened.openRouterAccountKey(at: .legacy) == "test-replacement-key")
		}
	}

	@Test func lockedStoreThrowsInteractionNotAllowedFromEveryRead() throws {
		try withTemporaryDirectory { directory in
			let (store, backing) = try ICloudKeychainStore.fixture(directory: directory)
			try store.storeCreditsAccount(
				CreditsAccount(appAccountToken: UUID(), key: "sk-or-test-0000"))
			backing.locked = true
			let expected = KeychainStoreError.keychain(errSecInteractionNotAllowed)
			#expect(throws: expected) { try store.creditsAccount() }
			#expect(throws: expected) { try store.intervalsConnection() }
			#expect(throws: expected) { try store.openRouterAccountKey(at: .legacy) }
			#expect(throws: expected) { try store.accessSelection() }
			#expect(throws: expected) { try store.prepareCreditsAccount() }
			#expect(throws: expected) { try store.delete(.creditsAccount) }
			backing.locked = false
			#expect(try store.creditsAccount()?.key == "sk-or-test-0000")
		}
	}

	@Test func failedWriteIsConsumedOnceAndLeavesTheStoredAccountIntact() throws {
		try withTemporaryDirectory { directory in
			let (store, backing) = try ICloudKeychainStore.fixture(directory: directory)
			let previous = try store.prepareCreditsAccount()
			let replacement = CreditsAccount(
				appAccountToken: previous.appAccountToken, key: "test-key")
			backing.failNextWrite = true
			#expect(throws: KeychainStoreError.keychain(errSecNotAvailable)) {
				try store.storeCreditsAccount(replacement)
			}
			#expect(!backing.failNextWrite)
			#expect(try store.creditsAccount() == previous)
			#expect(
				try ICloudKeychainStore.fixture(directory: directory).store.creditsAccount()
					== previous)
			try store.storeCreditsAccount(replacement)
			#expect(
				try ICloudKeychainStore.fixture(directory: directory).store.creditsAccount()
					== replacement)
			try store.delete(.creditsAccount)
			try store.delete(.creditsAccount)
			#expect(
				try ICloudKeychainStore.fixture(directory: directory).store.creditsAccount() == nil)
		}
	}

	@Test(arguments: [false, true], [nil, "test-previous-key"] as [String?])
	func fileMigrationPreservesCurrentAccountPrecedence(current: Bool, previousKey: String?)
		throws
	{
		try withTemporaryDirectory { directory in
			let previousToken = try #require(
				UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
			let previous = CreditsAccount(appAccountToken: previousToken, key: previousKey)
			let expected =
				current
				? CreditsAccount(appAccountToken: UUID(), key: "test-current-key") : previous
			var items = [
				"appAccountToken": Data(previousToken.uuidString.utf8),
				CredentialSlot.openRouterAccountKey.rawValue: Data("test-own-key".utf8),
				CredentialSlot.accessSelection.rawValue: Data(#"{"credits":{}}"#.utf8),
			]
			items["openRouterKey"] = previousKey.map { Data($0.utf8) }
			if current {
				items[CredentialSlot.creditsAccount.rawValue] = try JSONEncoder().encode(expected)
			}
			let file = directory.appending(path: FixtureSecretStoreBacking.fileName)
			try JSONEncoder().encode(items).write(to: file)
			let store = try ICloudKeychainStore.fixture(directory: directory).store
			let memory = ICloudKeychainStore(backing: FixtureSecretStoreBacking(items: items))
			#expect(try store.creditsAccount() == expected)
			#expect(try store.creditsAccount() == memory.creditsAccount())
			let migrated = try Data(contentsOf: file)
			let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
			let reopened = try ICloudKeychainStore.fixture(directory: directory).store
			#expect(try reopened.creditsAccount() == expected)
			#expect(try reopened.openRouterAccountKey(at: .legacy) == "test-own-key")
			#expect(try reopened.accessSelection() == .init(.credits))
			#expect(try Data(contentsOf: file) == migrated)
			let reopenedAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
			#expect(
				reopenedAttributes[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber]
					as? NSNumber)
			#expect(
				reopenedAttributes[.modificationDate] as? Date == attributes[.modificationDate]
					as? Date)
		}
	}

	@Test(arguments: [false, true])
	func legacyFileOnlyMintsATokenWhenPreparationNeedsOne(hasToken: Bool) throws {
		try withTemporaryDirectory { directory in
			let token = UUID()
			let items =
				hasToken
				? ["appAccountToken": Data(token.uuidString.utf8)]
				: ["openRouterKey": Data("test-legacy-key".utf8)]
			let file = directory.appending(path: FixtureSecretStoreBacking.fileName)
			let before = try JSONEncoder().encode(items)
			try before.write(to: file)
			let store = try ICloudKeychainStore.fixture(directory: directory).store
			let existing = try store.creditsAccount()
			#expect(existing?.appAccountToken == (hasToken ? token : nil))
			if !hasToken { #expect(try Data(contentsOf: file) == before) }
			let prepared = try store.prepareCreditsAccount()
			#expect(prepared.key == (hasToken ? nil : "test-legacy-key"))
			#expect(try store.prepareCreditsAccount() == prepared)
			#expect(
				try ICloudKeychainStore.fixture(directory: directory).store.creditsAccount()
					== prepared)
		}
	}

}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
	let directory = try TestTemporaryFolders.make()
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	defer {
		do {
			try FileManager.default.removeItem(at: directory)
		} catch {
			Issue.record(error, "temporary directory cleanup")
		}
	}
	try body(directory)
}
