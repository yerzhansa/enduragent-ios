import Foundation
import Testing

@testable import EnduragentCoach

@Suite final class FakeSecretStoreMigrationTests {
	let directory: URL

	init() throws {
		directory = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-legacy-secrets-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	deinit {
		do {
			try FileManager.default.removeItem(at: directory)
		} catch {
			Issue.record(error, "legacy fixture directory cleanup")
		}
	}

	var file: URL { directory.appending(path: FakeSecretStore.fileName) }

	@Test func fixtureStoreOpensALegacySecretsFile() async throws {
		try seed(
			"""
			{"appAccountToken":"11111111-2222-4333-8444-555555555555",
			 "openRouterKey":"test-legacy-key","intervalsApiKey":"test-training-key"}
			""")
		let store = try FakeSecretStore(directory: directory)
		try await expectIdentity(
			store, token: "11111111-2222-4333-8444-555555555555", key: "test-legacy-key")
		#expect(try store.intervalsConnection()?.credential == .apiKey("test-training-key"))
	}

	@Test(arguments: [
		"""
		{"appAccountToken":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
		 "openRouterKey":"test-interrupted-key",
		 "stagedIntervals":{"credits":{"previousKey":"test-previous-key",
		 "previousAppAccountToken":"11111111-2222-4333-8444-555555555555"}}}
		""",
		"""
		{"appAccountToken":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
		 "openRouterKey":"test-interrupted-key",
		 "stagedIntervals":{"credits":{
		 "previousAppAccountToken":"11111111-2222-4333-8444-555555555555"}}}
		""",
	])
	func fixtureStorePrefersALegacyUndoRecord(json: String) async throws {
		try seed(json)
		let store = try FakeSecretStore(directory: directory)
		let key = json.contains("previousKey") ? "test-previous-key" : nil
		try await expectIdentity(store, token: "11111111-2222-4333-8444-555555555555", key: key)
		let reopened = try FakeSecretStore(directory: directory)
		#expect(try reopened.creditsAccount() == store.creditsAccount())
	}

	@Test func fixtureStoreRewritesTheLegacyFileOnce() throws {
		try seed(
			"""
			{"appAccountToken":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
			 "openRouterKey":"test-interrupted-key","openRouterAccountKey":"test-own-key",
			 "stagedIntervals":{"credits":{"previousKey":"test-previous-key",
			 "previousAppAccountToken":"11111111-2222-4333-8444-555555555555"}},
			 "accessSelection":{"credits":{}},"intervalsApiKey":"test-training-key"}
			""")
		let first = try FakeSecretStore(directory: directory)
		let rewritten = try Data(contentsOf: file)
		let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
		let account = try #require(object["creditsAccount"] as? [String: String])
		#expect(
			account == [
				"appAccountToken": "11111111-2222-4333-8444-555555555555",
				"key": "test-previous-key",
			])
		#expect(object["appAccountToken"] == nil)
		#expect(object["openRouterKey"] == nil)
		#expect(object["stagedIntervals"] == nil)
		let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
		let second = try FakeSecretStore(directory: directory)
		#expect(try second.creditsAccount() == first.creditsAccount())
		#expect(try second.openRouterAccountKey() == "test-own-key")
		#expect(try second.accessSelection() == .credits)
		#expect(try second.intervalsConnection()?.credential == .apiKey("test-training-key"))
		#expect(try Data(contentsOf: file) == rewritten)
		let reopenedAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
		#expect(
			reopenedAttributes[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber]
				as? NSNumber)
		#expect(
			reopenedAttributes[.modificationDate] as? Date == attributes[.modificationDate] as? Date
		)
	}

	@Test func fixtureStoreKeepsTheCurrentAccountAheadOfLegacyFields() async throws {
		try seed(
			"""
			{"creditsAccount":{"appAccountToken":"99999999-2222-4333-8444-555555555555","key":"test-current-key"},
			 "appAccountToken":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","openRouterKey":"test-interrupted-key",
			 "stagedIntervals":{"credits":{"previousKey":"test-previous-key",
			 "previousAppAccountToken":"11111111-2222-4333-8444-555555555555"}}}
			""")
		try await expectIdentity(
			FakeSecretStore(directory: directory),
			token: "99999999-2222-4333-8444-555555555555", key: "test-current-key")
	}

	@Test func fixtureStoreOpensATokenOnlyV1File() async throws {
		try seed(#"{"appAccountToken":"11111111-2222-4333-8444-555555555555"}"#)
		try await expectIdentity(
			FakeSecretStore(directory: directory),
			token: "11111111-2222-4333-8444-555555555555", key: nil)
	}

	@Test func fixtureStoreWithoutATokenWaitsForPreparation() async throws {
		try seed(#"{"openRouterKey":"test-legacy-key"}"#)
		let before = try Data(contentsOf: file)
		let store = try FakeSecretStore(directory: directory)
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: nil, hasCreditsKey: false))
		#expect(await coach.status().setup == .needsAccessMethod)
		#expect(try store.creditsAccount() == nil)
		#expect(try Data(contentsOf: file) == before)
		let prepared = try store.prepareCreditsAccount()
		#expect(prepared.key == "test-legacy-key")
		#expect(try store.prepareCreditsAccount() == prepared)
		#expect(try FakeSecretStore(directory: directory).creditsAccount() == prepared)
	}

	private func seed(_ json: String) throws {
		try Data(json.utf8).write(to: file)
	}

	private func expectIdentity(_ store: FakeSecretStore, token raw: String, key: String?)
		async throws
	{
		let token = try #require(UUID(uuidString: raw))
		let coach = makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), secrets: store)
		#expect(
			try await coach.creditsIdentity()
				== CreditsIdentity(appAccountToken: token, hasCreditsKey: key != nil))
		#expect(try store.creditsAccount() == CreditsAccount(appAccountToken: token, key: key))
	}
}
