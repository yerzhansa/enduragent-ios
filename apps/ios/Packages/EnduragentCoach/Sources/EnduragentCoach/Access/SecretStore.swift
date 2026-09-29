import Foundation
import Security

public protocol SecretStore: Sendable {
	func creditsAccount() throws -> CreditsAccount
	func storeCreditsAccount(_ account: CreditsAccount) throws
	func openRouterAccountKey() throws -> String?
	func storeOpenRouterAccountKey(_ key: String) throws
	func intervalsConnection() throws -> IntervalsConnection?
	func storeIntervalsConnection(_ connection: IntervalsConnection) throws
	func accessSelection() throws -> AccessSelection?
	func storeAccessSelection(_ selection: AccessSelection) throws
	func delete(_ slot: CredentialSlot) throws
}

public struct KeychainStoreError: Error, Sendable, Equatable {
	public var status: OSStatus

	public init(status: OSStatus) {
		self.status = status
	}
}

package protocol SecretStoreBacking: Sendable {
	func add(account: String, data: Data) throws
	func copy(account: String) throws -> Data?
	func update(account: String, data: Data) throws
	func delete(account: String) throws
}

public struct ICloudKeychainStore: SecretStore {
	package static let serviceName = "icu.enduragent.ios"

	private let backing: any SecretStoreBacking

	public init() {
		self.backing = SecItemSecretStoreBacking(service: Self.serviceName)
	}

	package init(backing: any SecretStoreBacking) {
		self.backing = backing
	}

	private enum LegacyAccount: String, CaseIterable {
		case intervalsConnectionStaging
		case openRouterKey
		case appAccountToken
	}

	public func creditsAccount() throws -> CreditsAccount {
		if let account = try readItem(CreditsAccount.self, .creditsAccount) { return account }
		let migrated = try legacyCreditsAccount()
		let account: CreditsAccount
		do {
			try backing.add(
				account: CredentialSlot.creditsAccount.rawValue,
				data: JSONEncoder().encode(migrated))
			account = migrated
		} catch let error as KeychainStoreError where error.status == errSecDuplicateItem {
			guard let existing = try readItem(CreditsAccount.self, .creditsAccount) else {
				throw error
			}
			account = existing
		}
		for legacy in LegacyAccount.allCases {
			try backing.delete(account: legacy.rawValue)
		}
		return account
	}

	public func storeCreditsAccount(_ account: CreditsAccount) throws {
		try writeItem(account, .creditsAccount)
	}

	private func legacyCreditsAccount() throws -> CreditsAccount {
		if let staging = try backing.copy(
			account: LegacyAccount.intervalsConnectionStaging.rawValue)
		{
			do {
				let undo = try JSONDecoder().decode(LegacyCreditsUndo.self, from: staging)
				return CreditsAccount(
					appAccountToken: undo.credits.previousAppAccountToken,
					key: undo.credits.previousKey)
			} catch is DecodingError {
				return try legacyCreditsItems()
			}
		}
		return try legacyCreditsItems()
	}

	private func legacyCreditsItems() throws -> CreditsAccount {
		let key = try readString(account: LegacyAccount.openRouterKey.rawValue)
		let token: UUID
		if let raw = try readString(account: LegacyAccount.appAccountToken.rawValue) {
			guard let stored = UUID(uuidString: raw) else {
				throw KeychainStoreError(status: errSecDecode)
			}
			token = stored
		} else {
			token = UUID()
		}
		return CreditsAccount(appAccountToken: token, key: key)
	}

	public func openRouterAccountKey() throws -> String? {
		try readString(account: CredentialSlot.openRouterAccountKey.rawValue)
	}

	public func storeOpenRouterAccountKey(_ key: String) throws {
		try write(.openRouterAccountKey, Data(key.utf8))
	}

	public func intervalsConnection() throws -> IntervalsConnection? {
		try readItem(StoredIntervalsConnection.self, .intervalsConnection)?.connection()
	}

	public func storeIntervalsConnection(_ connection: IntervalsConnection) throws {
		try writeItem(StoredIntervalsConnection(connection), .intervalsConnection)
	}

	public func accessSelection() throws -> AccessSelection? {
		try readItem(StoredAccessSelection.self, .accessSelection)?.selection()
	}

	public func storeAccessSelection(_ selection: AccessSelection) throws {
		try writeItem(StoredAccessSelection(selection), .accessSelection)
	}

	public func delete(_ slot: CredentialSlot) throws {
		try backing.delete(account: slot.rawValue)
	}

	private func readString(account: String) throws -> String? {
		guard let data = try backing.copy(account: account) else { return nil }
		guard let string = String(data: data, encoding: .utf8) else {
			throw KeychainStoreError(status: errSecDecode)
		}
		return string
	}

	private func readItem<Item: Decodable>(_ type: Item.Type, _ slot: CredentialSlot) throws
		-> Item?
	{
		guard let data = try backing.copy(account: slot.rawValue) else {
			return nil
		}
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch is DecodingError {
			throw KeychainStoreError(status: errSecDecode)
		}
	}

	private func writeItem(_ item: some Encodable, _ slot: CredentialSlot) throws {
		try write(slot, try JSONEncoder().encode(item))
	}

	private func write(_ slot: CredentialSlot, _ data: Data) throws {
		if try backing.copy(account: slot.rawValue) == nil {
			try backing.add(account: slot.rawValue, data: data)
		} else {
			try backing.update(account: slot.rawValue, data: data)
		}
	}
}

private struct LegacyCreditsUndo: Decodable {
	struct Credits: Decodable {
		let previousKey: String?
		let previousAppAccountToken: UUID
	}

	let credits: Credits
}

package enum KeychainQuery {
	package static func item(service: String, account: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
		]
	}

	package static func add(service: String, account: String, data: Data) -> [String: Any] {
		var query = item(service: service, account: account)
		query[kSecValueData as String] = data
		query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		return query
	}

	package static func copy(service: String, account: String) -> [String: Any] {
		var query = item(service: service, account: account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		return query
	}

	package static func update(data: Data) -> [String: Any] {
		[
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
		]
	}
}

private struct SecItemSecretStoreBacking: SecretStoreBacking {
	var service: String

	func add(account: String, data: Data) throws {
		let status = SecItemAdd(
			KeychainQuery.add(service: service, account: account, data: data) as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw KeychainStoreError(status: status)
		}
	}

	func copy(account: String) throws -> Data? {
		var result: AnyObject?
		let status = SecItemCopyMatching(
			KeychainQuery.copy(service: service, account: account) as CFDictionary, &result)
		if status == errSecItemNotFound {
			return nil
		}
		guard status == errSecSuccess else {
			throw KeychainStoreError(status: status)
		}
		guard let data = result as? Data else {
			throw KeychainStoreError(status: errSecDecode)
		}
		return data
	}

	func update(account: String, data: Data) throws {
		let status = SecItemUpdate(
			KeychainQuery.item(service: service, account: account) as CFDictionary,
			KeychainQuery.update(data: data) as CFDictionary
		)
		guard status == errSecSuccess else {
			throw KeychainStoreError(status: status)
		}
	}

	func delete(account: String) throws {
		let status = SecItemDelete(
			KeychainQuery.item(service: service, account: account) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw KeychainStoreError(status: status)
		}
	}
}
