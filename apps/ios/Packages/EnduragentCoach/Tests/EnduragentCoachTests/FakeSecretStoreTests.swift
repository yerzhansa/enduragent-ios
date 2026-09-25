import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct FakeSecretStoreTests {
	@Test func directoryStorePersistsAcrossInstances() throws {
		let directory = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-secrets-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let first = try FakeSecretStore(directory: directory)
		try first.storeOpenRouterKey("sk-or-test-0000")
		try first.storeIntervalsCredential(.apiKey("fixture"))
		let token = try first.appAccountToken()
		let second = try FakeSecretStore(directory: directory)
		#expect(try second.openRouterKey() == "sk-or-test-0000")
		#expect(try second.intervalsCredential() == .apiKey("fixture"))
		#expect(try second.appAccountToken() == token)
	}

	@Test func lockedStoreThrowsInteractionNotAllowedFromEveryRead() throws {
		let store = FakeSecretStore()
		try store.storeOpenRouterKey("sk-or-test-0000")
		store.locked = true
		let expected = KeychainStoreError(status: errSecInteractionNotAllowed)
		#expect(throws: expected) { try store.openRouterKey() }
		#expect(throws: expected) { try store.intervalsCredential() }
		#expect(throws: expected) { try store.appAccountToken() }
		store.locked = false
		#expect(try store.openRouterKey() == "sk-or-test-0000")
	}
}
