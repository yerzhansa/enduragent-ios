import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct FakeSecretStoreTests {
	@Test func directoryStorePersistsAcrossInstances() throws {
		try withTemporaryDirectory { directory in
			let first = try FakeSecretStore(directory: directory)
			try first.storeOpenRouterKey("sk-or-test-0000")
			try first.storeIntervalsConnection(testConnection)
			let token = try first.appAccountToken()
			let second = try FakeSecretStore(directory: directory)
			#expect(try second.openRouterKey() == "sk-or-test-0000")
			#expect(try second.intervalsConnection() == testConnection)
			#expect(try second.appAccountToken() == token)
		}
	}

	@Test func failedStagingDeletionKeepsThePreviousCreditsPair() throws {
		try withTemporaryDirectory { directory in
			let store = try FakeSecretStore(directory: directory)
			let oldToken = try store.appAccountToken()
			try store.storeOpenRouterKey("test-old-credits-key")
			let previous = CredentialReplacement.credits(
				previousKey: "test-old-credits-key", previousAppAccountToken: oldToken)
			try store.stageReplacement(previous)
			try store.storeOpenRouterKey("test-new-credits-key")
			try store.storeAppAccountToken(UUID())
			let file = directory.appending(path: FakeSecretStore.fileName)
			try FileManager.default.removeItem(at: file)
			try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
			#expect(throws: CocoaError.self) { try store.delete(.intervalsConnectionStaging) }
			#expect(try store.stagedReplacement() == previous)
			#expect(try store.openRouterKey() == "test-old-credits-key")
			#expect(try store.appAccountToken() == oldToken)
		}
	}

	@Test func lockedStoreThrowsInteractionNotAllowedFromEveryRead() throws {
		let store = FakeSecretStore()
		try store.storeOpenRouterKey("sk-or-test-0000")
		store.locked = true
		let expected = KeychainStoreError(status: errSecInteractionNotAllowed)
		#expect(throws: expected) { try store.openRouterKey() }
		#expect(throws: expected) { try store.intervalsConnection() }
		#expect(throws: expected) { try store.appAccountToken() }
		store.locked = false
		#expect(try store.openRouterKey() == "sk-or-test-0000")
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
