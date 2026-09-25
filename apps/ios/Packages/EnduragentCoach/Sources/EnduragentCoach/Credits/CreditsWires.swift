import Foundation
import Security

public struct AthleteKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible
{
	public var secret: String
	public init(secret: String) {
		self.secret = secret
	}

	public var description: String {
		"AthleteKey(redacted)"
	}

	public var debugDescription: String {
		description
	}
}

struct GrantBody: Encodable {
	var athleteId: String
	var deviceCheckToken: String
}

struct SignedTransactionBody: Encodable {
	var signedTransaction: String
}

struct ErrorWire: Decodable {
	var error: String
}

struct KindWire: Decodable {
	var kind: String
}

struct GrantMintedWire: Decodable {
	var key: String
	var credits: Int
}

struct GrantToppedUpWire: Decodable {
	var added: Int
}

struct ClaimMintedWire: Decodable {
	var key: String
	var creditsAdded: Int
}

struct ClaimToppedUpWire: Decodable {
	var creditsAdded: Int
}

struct RecoveredWire: Decodable {
	var athleteId: UUID
	var key: String
	var credits: Int
}

struct CatalogWire: Decodable {
	var purchasesEnabled: Bool
	var creditsPerUsd: Int
	var packs: [CatalogPackWire]
}

struct CatalogPackWire: Decodable {
	var productId: String
	var credits: Int
}

struct OpenRouterKeyWire: Decodable {
	var data: OpenRouterKeyDataWire
}

struct OpenRouterKeyDataWire: Decodable {
	var limit_remaining: Double?
}

enum KeychainAccount {
	static let appAccountToken = "appAccountToken"
	static let openRouterKey = "openRouterKey"
	static let intervalsCredential = "intervalsCredential"
}

enum StoredIntervalsCredential: Codable {
	case apiKey(String)
	case oauth(access: String, refresh: String)

	init(_ credential: IntervalsCredential) {
		switch credential {
		case .apiKey(let key):
			self = .apiKey(key)
		case .oauth(let access, let refresh):
			self = .oauth(access: access, refresh: refresh)
		}
	}

	var credential: IntervalsCredential {
		switch self {
		case .apiKey(let key):
			return .apiKey(key)
		case .oauth(let access, let refresh):
			return .oauth(access: access, refresh: refresh)
		}
	}
}

struct SecItemSecretStoreBacking: SecretStoreBacking {
	var service: String
	var accessGroup: String?

	func add(account: String, data: Data) throws {
		var query = baseQuery(account: account)
		query[kSecValueData as String] = data
		query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw KeychainStoreError(status: status)
		}
	}

	func copy(account: String) throws -> Data? {
		var query = baseQuery(account: account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
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
			baseQuery(account: account) as CFDictionary,
			[kSecValueData as String: data] as CFDictionary
		)
		guard status == errSecSuccess else {
			throw KeychainStoreError(status: status)
		}
	}

	func baseQuery(account: String) -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
		]
		if let accessGroup {
			query[kSecAttrAccessGroup as String] = accessGroup
		}
		return query
	}
}
