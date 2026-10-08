import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct KeychainStoreTests {
	@Test func appAccountTokenIsStable() throws {
		let memory = FixtureSecretStoreBacking()
		let first = ICloudKeychainStore(backing: memory)
		let second = ICloudKeychainStore(backing: memory)
		let token = try first.prepareCreditsAccount().appAccountToken
		#expect(try first.creditsAccount()?.appAccountToken == token)
		#expect(try second.creditsAccount()?.appAccountToken == token)
	}

	@Test func keysConnectionAndSelectionRoundTrip() throws {
		let store = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		#expect(try store.creditsAccount()?.key == nil)
		#expect(try store.intervalsConnection() == nil)
		#expect(try store.accessSelection() == nil)
		try store.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: UUID(), key: "test-or-key"))
		try store.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: UUID(), key: "test-or-key-rotated")
		)
		#expect(try store.creditsAccount()?.key == "test-or-key-rotated")
		try store.storeOpenRouterAccountKey("test-or-account-key", at: .legacy)
		#expect(try store.openRouterAccountKey(at: .legacy) == "test-or-account-key")
		try store.storeIntervalsConnection(testConnection)
		#expect(try store.intervalsConnection() == testConnection)
		let oauth = IntervalsConnection(
			id: ConnectionID(), credential: .oauth(access: "a", refresh: "r"),
			selection: .athlete(try #require(IntervalsAthleteID(rawValue: "i2002"))),
			resolvedAthlete: nil)
		try store.storeIntervalsConnection(oauth)
		#expect(try store.intervalsConnection() == oauth)
		let selection = SavedAccessReference(
			.openRouter(
				SavedOpenRouterReference(
					credential: .legacy, model: ModelID(rawValue: "test/account-model"))))
		try store.storeAccessSelection(selection)
		#expect(try store.accessSelection() == selection)
	}

	@Test func deleteRemovesOnlyItsSlotAndRepeatsSafely() throws {
		let store = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try store.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: UUID(), key: "test-or-key"))
		try store.storeIntervalsConnection(testConnection)
		try store.delete(.intervalsConnection)
		try store.delete(.intervalsConnection)
		#expect(try store.intervalsConnection() == nil)
		#expect(try store.creditsAccount()?.key == "test-or-key")
	}

	@Test(arguments: [
		#"{"apiKey":{"_0":"icu-v1-key"}}"#,
		#"{"credential":{"apiKey":{"_0":"icu-v1-key"}}}"#,
	])
	func legacyIntervalsItemGainsAStableIdOnRead(_ legacy: String) throws {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer {
			do {
				try FileManager.default.removeItem(at: directory)
			} catch {
				Issue.record(error, "legacy connection directory cleanup")
			}
		}
		let (store, backing) = try ICloudKeychainStore.fixture(directory: directory)
		try backing.add(
			account: CredentialSlot.intervalsConnection.rawValue, data: Data(legacy.utf8))
		let first = try #require(try store.intervalsConnection())
		let second = try #require(try store.intervalsConnection())
		let id = first.id
		#expect(id.rawValue.uuidString == "A7005915-31F4-86C4-8B4C-2DDDC138C432")
		#expect(second.id == id)
		#expect(first.credential == .apiKey("icu-v1-key"))
		#expect(first.selection == .keyOwner)
		#expect(first.resolvedAthlete == nil)
		let reopened = try ICloudKeychainStore.fixture(directory: directory).store
		#expect(try reopened.intervalsConnection() == first)
		#expect(backing.writes(to: CredentialSlot.intervalsConnection.rawValue) == 1)
		#expect(
			try backing.copy(account: CredentialSlot.intervalsConnection.rawValue)
				== Data(legacy.utf8))
		try store.storeIntervalsConnection(first)
		let persisted = try #require(
			try backing.copy(account: CredentialSlot.intervalsConnection.rawValue))
		#expect(
			try JSONDecoder().decode(StoredIntervalsConnection.self, from: persisted).id
				== id.rawValue)
		let rewritten = try ICloudKeychainStore.fixture(directory: directory).store
		#expect(try rewritten.intervalsConnection() == first)
	}

	@Test func concurrentLegacyReadersShareOneIdentity() async throws {
		let backing = FixtureSecretStoreBacking(items: [
			CredentialSlot.intervalsConnection.rawValue: Data(
				#"{"apiKey":{"_0":"icu-v1-key"}}"#.utf8)
		])
		let connections = try await withThrowingTaskGroup(of: IntervalsConnection.self) { group in
			for _ in 0..<20 {
				group.addTask {
					try #require(try ICloudKeychainStore(backing: backing).intervalsConnection())
				}
			}
			return try await group.reduce(into: []) { $0.append($1) }
		}
		let first = try #require(connections.first)
		#expect(connections.allSatisfy { $0 == first })
		#expect(try ICloudKeychainStore(backing: backing).intervalsConnection() == first)
		#expect(backing.writes(to: CredentialSlot.intervalsConnection.rawValue) == 0)
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
		let token = try first.prepareCreditsAccount().appAccountToken
		#expect(try first.creditsAccount()?.appAccountToken == token)
		#expect(try second.creditsAccount()?.appAccountToken == token)
	}
}
