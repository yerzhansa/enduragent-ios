import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct KeychainStoreTests {
	@Test func appAccountTokenIsStable() throws {
		let memory = MemorySecretStoreBacking()
		let first = ICloudKeychainStore(backing: memory)
		let second = ICloudKeychainStore(backing: memory)
		let token = try first.creditsAccount().appAccountToken
		#expect(try first.creditsAccount().appAccountToken == token)
		#expect(try second.creditsAccount().appAccountToken == token)
	}

	@Test func keysConnectionAndSelectionRoundTrip() throws {
		let store = ICloudKeychainStore(backing: MemorySecretStoreBacking())
		#expect(try store.creditsAccount().key == nil)
		#expect(try store.intervalsConnection() == nil)
		#expect(try store.accessSelection() == nil)
		try store.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: store.creditsAccount().appAccountToken, key: "test-or-key"))
		try store.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: store.creditsAccount().appAccountToken, key: "test-or-key-rotated")
		)
		#expect(try store.creditsAccount().key == "test-or-key-rotated")
		try store.storeOpenRouterAccountKey("test-or-account-key")
		#expect(try store.openRouterAccountKey() == "test-or-account-key")
		try store.storeIntervalsConnection(testConnection)
		#expect(try store.intervalsConnection() == testConnection)
		let oauth = IntervalsConnection(
			id: ConnectionID(), credential: .oauth(access: "a", refresh: "r"),
			selection: .athlete(try #require(IntervalsAthleteID(rawValue: "i2002"))),
			resolvedAthlete: nil)
		try store.storeIntervalsConnection(oauth)
		#expect(try store.intervalsConnection() == oauth)
		let selection = AccessSelection.openRouterAccount(
			model: ModelID(rawValue: "test/account-model"),
			consent: ProviderConsent(
				provider: "Test Provider", model: ModelID(rawValue: "test/account-model"),
				at: Date(timeIntervalSince1970: 897_897_600)))
		try store.storeAccessSelection(selection)
		#expect(try store.accessSelection() == selection)
	}

	@Test func deleteRemovesOnlyItsSlotAndRepeatsSafely() throws {
		let store = ICloudKeychainStore(backing: MemorySecretStoreBacking())
		try store.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: store.creditsAccount().appAccountToken, key: "test-or-key"))
		try store.storeIntervalsConnection(testConnection)
		try store.delete(.intervalsConnection)
		try store.delete(.intervalsConnection)
		#expect(try store.intervalsConnection() == nil)
		#expect(try store.creditsAccount().key == "test-or-key")
	}

	@Test func v1IntervalsItemDecodesWithNilConnectionIdAndIsRewrittenOnce() async throws {
		let memory = MemorySecretStoreBacking(items: [
			CredentialSlot.intervalsConnection.rawValue: Data(
				#"{"apiKey":{"_0":"icu-v1-key"}}"#.utf8)
		])
		let store = ICloudKeychainStore(backing: memory)
		let v1 = try #require(try store.intervalsConnection())
		#expect(v1.id == nil)
		#expect(v1.credential == .apiKey("icu-v1-key"))
		#expect(v1.selection == .keyOwner)
		#expect(v1.resolvedAthlete == nil)
		let vault = testVault(store)
		let first = try await vault.trainingConnection()
		let second = try await vault.trainingConnection()
		guard case .intervals(let connection, nil) = first.account else {
			Issue.record("expected an intervals account, got \(first.account)")
			return
		}
		#expect(second.account == first.account)
		#expect(try store.intervalsConnection()?.id == connection)
		#expect(try store.intervalsConnection()?.credential == .apiKey("icu-v1-key"))
		#expect(memory.writes(to: CredentialSlot.intervalsConnection.rawValue) == 1)
	}

	@Test func everyItemIsSynchronizableAndReadableAfterFirstUnlock() {
		let add = KeychainQuery.add(service: "test", account: "slot", data: Data([0x01]))
		let update = KeychainQuery.update(data: Data([0x02]))
		let match = KeychainQuery.item(service: "test", account: "slot")
		#expect(add[kSecAttrSynchronizable as String] as? Bool == true)
		#expect(match[kSecAttrSynchronizable as String] as? Bool == true)
		#expect(
			KeychainQuery.copy(service: "test", account: "slot")[kSecAttrSynchronizable as String]
				as? Bool == true)
		for attributes in [add, update] {
			#expect(
				attributes[kSecAttrAccessible as String] as? String
					== kSecAttrAccessibleAfterFirstUnlock as String)
		}
	}

	@Test(.enabled(if: ProcessInfo.processInfo.environment["ENDURAGENT_KEYCHAIN_TESTS"] == "1"))
	func appAccountTokenIsStableOnSecItem() throws {
		let first = ICloudKeychainStore()
		let second = ICloudKeychainStore()
		let token = try first.creditsAccount().appAccountToken
		#expect(try first.creditsAccount().appAccountToken == token)
		#expect(try second.creditsAccount().appAccountToken == token)
	}
}

final class MemorySecretStoreBacking: SecretStoreBacking, @unchecked Sendable {
	private let lock = NSLock()
	private var items: [String: Data]
	private var copied: [String] = []
	var readCount: Int { lock.withLock { copied.count } }
	var readAccounts: [String] { lock.withLock { copied } }
	private var deleted: [String] = []
	var deletedAccounts: [String] { lock.withLock { deleted } }
	private var written: [String: Int] = [:]
	private var failures: [String: OSStatus] = [:]
	private var writeFailures: [String: OSStatus] = [:]

	init(items: [String: Data] = [:]) {
		self.items = items
	}

	func fail(_ account: String, with status: OSStatus?) {
		lock.withLock { failures[account] = status }
	}

	func failWrites(_ account: String, with status: OSStatus?) {
		lock.withLock { writeFailures[account] = status }
	}

	func writes(to account: String) -> Int {
		lock.withLock { written[account, default: 0] }
	}

	func add(account: String, data: Data) throws {
		try lock.withLock {
			try check(account, writing: true)
			if items[account] != nil {
				throw KeychainStoreError(status: errSecDuplicateItem)
			}
			items[account] = data
			written[account, default: 0] += 1
		}
	}

	func copy(account: String) throws -> Data? {
		try lock.withLock {
			copied.append(account)
			try check(account)
			return items[account]
		}
	}

	func update(account: String, data: Data) throws {
		try lock.withLock {
			try check(account, writing: true)
			guard items[account] != nil else {
				throw KeychainStoreError(status: errSecItemNotFound)
			}
			items[account] = data
			written[account, default: 0] += 1
		}
	}

	func delete(account: String) throws {
		try lock.withLock {
			try check(account)
			items[account] = nil
			deleted.append(account)
		}
	}

	private func check(_ account: String, writing: Bool = false) throws {
		if let status = failures[account] ?? (writing ? writeFailures[account] : nil) {
			throw KeychainStoreError(status: status)
		}
	}
}
