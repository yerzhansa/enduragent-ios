import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct FakeSecretStoreTests {
	@Test func directoryStorePersistsAcrossInstances() throws {
		try withTemporaryDirectory { directory in
			let first = try FakeSecretStore(directory: directory)
			try first.storeCreditsAccount(
				CreditsAccount(
					appAccountToken: first.creditsAccount().appAccountToken, key: "sk-or-test-0000")
			)
			try first.storeIntervalsConnection(testConnection)
			let token = try first.creditsAccount().appAccountToken
			let second = try FakeSecretStore(directory: directory)
			#expect(try second.creditsAccount().key == "sk-or-test-0000")
			#expect(try second.intervalsConnection() == testConnection)
			#expect(try second.creditsAccount().appAccountToken == token)
		}
	}

	@Test func failedAccountPersistenceKeepsThePreviousCreditsPair() throws {
		try withTemporaryDirectory { directory in
			let store = try FakeSecretStore(directory: directory)
			let previous = CreditsAccount(appAccountToken: UUID(), key: "test-old-credits-key")
			try store.storeCreditsAccount(previous)
			let file = directory.appending(path: FakeSecretStore.fileName)
			try FileManager.default.removeItem(at: file)
			try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
			#expect(throws: CocoaError.self) {
				try store.storeCreditsAccount(
					CreditsAccount(appAccountToken: UUID(), key: "test-new-credits-key"))
			}
			#expect(try store.creditsAccount() == previous)
		}
	}

	@Test func lockedStoreThrowsInteractionNotAllowedFromEveryRead() throws {
		let store = FakeSecretStore()
		try store.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: store.creditsAccount().appAccountToken, key: "sk-or-test-0000"))
		store.locked = true
		let expected = KeychainStoreError(status: errSecInteractionNotAllowed)
		#expect(throws: expected) { try store.creditsAccount() }
		#expect(throws: expected) { try store.intervalsConnection() }
		#expect(throws: expected) { try store.openRouterAccountKey() }
		#expect(throws: expected) { try store.accessSelection() }
		store.locked = false
		#expect(try store.creditsAccount().key == "sk-or-test-0000")
	}
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
	let directory = FileManager.default.temporaryDirectory.appending(
		path: "enduragent-secrets-\(UUID().uuidString)", directoryHint: .isDirectory)
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
