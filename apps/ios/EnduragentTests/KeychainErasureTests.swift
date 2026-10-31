import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@Suite(.serialized) struct KeychainErasureTests {
	private let service = NativeKeychainProof.service
	private let neighbour = "icu.enduragent.ios.erasure-neighbour"

	@Test(.enabled(if: ProcessInfo.processInfo.environment["ENDURAGENT_KEYCHAIN_TESTS"] == "1"))
	func deleteEverythingRemovesSynchronizedAndThisDeviceOnlyItemsOfTheService() throws {
		let store = NativeKeychainProof().store()
		try store.deleteEverything()
		try remove(service: neighbour)
		_ = try store.prepareCreditsAccount()
		try store.storeOpenRouterAccountKey("synthetic-erasure-key", at: .legacy)
		try add(account: "device-only", synchronizable: false, service: service)
		try add(account: "kept", synchronizable: true, service: neighbour)
		#expect(try accounts(service: service).count == 3)
		#expect(try accounts(service: service).contains("device-only"))

		try store.deleteEverything()
		try store.deleteEverything()

		#expect(try accounts(service: service).isEmpty)
		#expect(try store.creditsAccount() == nil)
		#expect(try accounts(service: neighbour) == ["kept"])
		try remove(service: neighbour)
	}

	private func add(account: String, synchronizable: Bool, service: String) throws {
		let status = SecItemAdd(
			[
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: account,
				kSecAttrSynchronizable as String: synchronizable,
				kSecValueData as String: Data("synthetic".utf8),
			] as CFDictionary, nil)
		try #require(status == errSecSuccess, "SecItemAdd returned \(status)")
	}

	private func accounts(service: String) throws -> Set<String> {
		var result: CFTypeRef?
		let status = SecItemCopyMatching(
			[
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
				kSecReturnAttributes as String: true,
				kSecMatchLimit as String: kSecMatchLimitAll,
			] as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		try #require(status == errSecSuccess, "SecItemCopyMatching returned \(status)")
		let items = try #require(result as? [[String: Any]])
		return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
	}

	private func remove(service: String) throws {
		let status = SecItemDelete(
			[
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
			] as CFDictionary)
		try #require(
			status == errSecSuccess || status == errSecItemNotFound,
			"SecItemDelete returned \(status)")
	}
}
