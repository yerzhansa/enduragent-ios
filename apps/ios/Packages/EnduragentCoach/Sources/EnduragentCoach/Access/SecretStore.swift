import Foundation
import Security

public protocol SecretStore: Sendable {
	func creditsAccount() throws -> CreditsAccount?
	func prepareCreditsAccount() throws -> CreditsAccount
	func storeCreditsAccount(_ account: CreditsAccount) throws
	func openRouterAccountKey(at reference: OpenRouterCredentialRef) throws -> String?
	func storeOpenRouterAccountKey(_ key: String, at reference: OpenRouterCredentialRef) throws
	func deleteOpenRouterAccountKey(at reference: OpenRouterCredentialRef) throws
	func intervalsConnection() throws -> IntervalsConnection?
	func storeIntervalsConnection(_ connection: IntervalsConnection) throws
	func accessSelection() throws -> SavedAccessReference?
	func storeAccessSelection(_ reference: SavedAccessReference) throws
	func delete(_ slot: CredentialSlot) throws
}

public enum KeychainStoreError: Error, Sendable, Equatable {
	case keychain(OSStatus)
	case encoding
	case fileSystem(Int)
	case unexpected

	public var status: OSStatus? {
		guard case .keychain(let status) = self else { return nil }
		return status
	}

	init(_ error: any Error) {
		switch error {
		case let failure as KeychainStoreError: self = failure
		case is EncodingError: self = .encoding
		case let failure as CocoaError: self = .fileSystem(failure.code.rawValue)
		default: self = .unexpected
		}
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

	package init(
		nativeService: String, recordAttempt: @escaping @Sendable (NativeKeychainAttempt) -> Void
	) {
		self.backing = SecItemSecretStoreBacking(
			service: nativeService, recordAttempt: recordAttempt)
	}

	private enum LegacyAccount: String, CaseIterable {
		case openRouterKey
		case appAccountToken
	}

	public func creditsAccount() throws -> CreditsAccount? {
		if let current = try readItem(CreditsAccount.self, .creditsAccount) { return current }
		let key = try readString(account: LegacyAccount.openRouterKey.rawValue)
		guard let token = try legacyCreditsToken() else { return nil }
		let account = try addCreditsAccount(CreditsAccount(appAccountToken: token, key: key))
		try deleteLegacyCreditsItems()
		return account
	}

	public func prepareCreditsAccount() throws -> CreditsAccount {
		if let account = try creditsAccount() { return account }
		let legacyKey = try readString(account: LegacyAccount.openRouterKey.rawValue)
		let account = try addCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: legacyKey))
		if legacyKey != nil { try deleteLegacyCreditsItems() }
		return account
	}

	private func deleteLegacyCreditsItems() throws {
		for legacy in LegacyAccount.allCases {
			try backing.delete(account: legacy.rawValue)
		}
	}

	private func addCreditsAccount(_ candidate: CreditsAccount) throws -> CreditsAccount {
		do {
			try backing.add(
				account: CredentialSlot.creditsAccount.rawValue,
				data: JSONEncoder().encode(candidate))
			return candidate
		} catch let error as KeychainStoreError where error.status == errSecDuplicateItem {
			guard let existing = try readItem(CreditsAccount.self, .creditsAccount) else {
				throw error
			}
			return existing
		}
	}

	public func storeCreditsAccount(_ account: CreditsAccount) throws {
		try writeItem(account, .creditsAccount)
	}

	private func legacyCreditsToken() throws -> UUID? {
		guard let raw = try readString(account: LegacyAccount.appAccountToken.rawValue) else {
			return nil
		}
		guard let token = UUID(uuidString: raw) else {
			throw KeychainStoreError.keychain(errSecDecode)
		}
		return token
	}

	public func openRouterAccountKey(at reference: OpenRouterCredentialRef) throws -> String? {
		try readString(account: reference.account)
	}

	public func storeOpenRouterAccountKey(_ key: String, at reference: OpenRouterCredentialRef)
		throws
	{
		try write(account: reference.account, Data(key.utf8))
	}

	public func intervalsConnection() throws -> IntervalsConnection? {
		try readItem(StoredIntervalsConnection.self, .intervalsConnection)?.connection()
	}

	public func deleteOpenRouterAccountKey(at reference: OpenRouterCredentialRef) throws {
		try backing.delete(account: reference.account)
	}

	public func storeIntervalsConnection(_ connection: IntervalsConnection) throws {
		try writeItem(StoredIntervalsConnection(connection), .intervalsConnection)
	}

	public func accessSelection() throws -> SavedAccessReference? {
		try readItem(StoredAccessSelection.self, .accessSelection)?.selection()
	}

	public func storeAccessSelection(_ reference: SavedAccessReference) throws {
		try writeItem(StoredAccessSelection(reference), .accessSelection)
	}

	public func delete(_ slot: CredentialSlot) throws {
		try backing.delete(account: slot.rawValue)
	}

	private func readString(account: String) throws -> String? {
		guard let data = try backing.copy(account: account) else { return nil }
		guard let string = String(data: data, encoding: .utf8) else {
			throw KeychainStoreError.keychain(errSecDecode)
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
			throw KeychainStoreError.keychain(errSecDecode)
		}
	}

	private func writeItem(_ item: some Encodable, _ slot: CredentialSlot) throws {
		try write(slot, try JSONEncoder().encode(item))
	}

	private func write(_ slot: CredentialSlot, _ data: Data) throws {
		try write(account: slot.rawValue, data)
	}

	private func write(account: String, _ data: Data) throws {
		if try backing.copy(account: account) == nil {
			try backing.add(account: account, data: data)
		} else {
			try backing.update(account: account, data: data)
		}
	}
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
	var recordAttempt: (@Sendable (NativeKeychainAttempt) -> Void)?

	func add(account: String, data: Data) throws {
		let start = DispatchTime.now().uptimeNanoseconds
		let status = SecItemAdd(
			KeychainQuery.add(service: service, account: account, data: data) as CFDictionary, nil)
		recordAttempt?(.init(operation: "add", slot: account, status: status, start: start))
		guard status == errSecSuccess else {
			throw KeychainStoreError.keychain(status)
		}
	}

	func copy(account: String) throws -> Data? {
		var result: AnyObject?
		let start = DispatchTime.now().uptimeNanoseconds
		let status = SecItemCopyMatching(
			KeychainQuery.copy(service: service, account: account) as CFDictionary, &result)
		recordAttempt?(.init(operation: "copy", slot: account, status: status, start: start))
		if status == errSecItemNotFound {
			return nil
		}
		guard status == errSecSuccess else {
			throw KeychainStoreError.keychain(status)
		}
		guard let data = result as? Data else {
			throw KeychainStoreError.keychain(errSecDecode)
		}
		return data
	}

	func update(account: String, data: Data) throws {
		let start = DispatchTime.now().uptimeNanoseconds
		let status = SecItemUpdate(
			KeychainQuery.item(service: service, account: account) as CFDictionary,
			KeychainQuery.update(data: data) as CFDictionary
		)
		recordAttempt?(.init(operation: "update", slot: account, status: status, start: start))
		guard status == errSecSuccess else {
			throw KeychainStoreError.keychain(status)
		}
	}

	func delete(account: String) throws {
		let start = DispatchTime.now().uptimeNanoseconds
		let status = SecItemDelete(
			KeychainQuery.item(service: service, account: account) as CFDictionary)
		recordAttempt?(.init(operation: "delete", slot: account, status: status, start: start))
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw KeychainStoreError.keychain(status)
		}
	}
}

package struct NativeKeychainAttempt: Codable, Sendable {
	package let operation: String
	package let slot: String
	package let status: OSStatus
	package let milliseconds: Double

	init(operation: String, slot: String, status: OSStatus, start: UInt64) {
		self.operation = operation
		self.slot = slot
		self.status = status
		self.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
	}
}
