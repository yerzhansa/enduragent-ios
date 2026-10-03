import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite final class LegacyFixtureSecretStoreTests {
	let directory: URL

	init() throws {
		directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	deinit {
		do {
			try FileManager.default.removeItem(at: directory)
		} catch {
			Issue.record(error, "legacy fixture directory cleanup")
		}
	}

	@Test(arguments: [
		(#"{"intervalsApiKey":"test"}"#, IntervalsCredential.apiKey("test")),
		(
			#"{"intervalsOAuthAccess":"test","intervalsOAuthRefresh":"data"}"#,
			IntervalsCredential.oauth(access: "test", refresh: "data")
		),
		(
			#"{"intervalsApiKey":"test","intervalsOAuthAccess":"other","intervalsOAuthRefresh":"other"}"#,
			IntervalsCredential.apiKey("test")
		),
	])
	func v1IntervalsFieldsOpenAndSurviveRewriting(legacy: String, expected: IntervalsCredential)
		throws
	{
		try write(legacy)
		let store = try ICloudKeychainStore.fixture(directory: directory).store
		#expect(try store.intervalsConnection()?.credential == expected)
		#expect(try store.intervalsConnection()?.selection == .keyOwner)
		try store.storeOpenRouterAccountKey("test-own-key", at: .legacy)
		let reopened = try ICloudKeychainStore.fixture(directory: directory).store
		#expect(try reopened.intervalsConnection()?.credential == expected)
		#expect(try reopened.openRouterAccountKey(at: .legacy) == "test-own-key")
	}

	@Test(arguments: [false, true])
	func currentAccountKeepsTheRealMigrationPrecedence(hasCurrent: Bool) throws {
		let currentToken = try #require(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
		var fields: [String: Any] = [
			"appAccountToken": currentToken.uuidString,
			"openRouterKey": "test-interrupted-key",
			"openRouterAccountKey": "test-own-key",
			"intervals": ["credential": ["apiKey": ["_0": "test-current-training-key"]]],
			"intervalsApiKey": "test-old-training-key",
			"accessSelection": ["credits": [:]],
		]
		if hasCurrent {
			fields["creditsAccount"] = [
				"appAccountToken": currentToken.uuidString, "key": "test-current-key",
			]
		}
		try JSONSerialization.data(withJSONObject: fields).write(
			to: directory.appending(path: "secrets.json"))
		let (store, backing) = try ICloudKeychainStore.fixture(directory: directory)
		#expect(backing.writeCount == 0)
		let expected = CreditsAccount(
			appAccountToken: currentToken,
			key: hasCurrent ? "test-current-key" : "test-interrupted-key")
		#expect(try store.creditsAccount() == expected)
		#expect(try store.intervalsConnection()?.credential == .apiKey("test-current-training-key"))
		#expect(try store.accessSelection() == .init(.credits))
		#expect(try store.openRouterAccountKey(at: .legacy) == "test-own-key")
		try store.storeCreditsAccount(expected)
		let reopened = try ICloudKeychainStore.fixture(directory: directory).store
		#expect(try reopened.creditsAccount() == expected)
		#expect(
			try reopened.intervalsConnection()?.credential == .apiKey("test-current-training-key"))
		#expect(try reopened.accessSelection() == .init(.credits))
		#expect(try reopened.openRouterAccountKey(at: .legacy) == "test-own-key")
	}

	@Test func corruptSelectionDoesNotBlockCredits() async throws {
		try write(
			#"{"creditsAccount":{"appAccountToken":"11111111-2222-4333-8444-555555555555","key":"test-key"},"accessSelection":"garbage"}"#
		)
		let store = try ICloudKeychainStore.fixture(directory: directory).store
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		#expect(try await coach.creditsIdentity().hasCreditsKey)
		#expect(throws: KeychainStoreError.keychain(errSecDecode)) { try store.accessSelection() }
	}

	@Test func v1TokenOpensWithoutOtherFields() async throws {
		try write(#"{"appAccountToken":"11111111-2222-4333-8444-555555555555"}"#)
		let store = try ICloudKeychainStore.fixture(directory: directory).store
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		let token = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: false))
	}

	private func write(_ legacy: String) throws {
		try Data(legacy.utf8).write(to: directory.appending(path: "secrets.json"))
	}
}
