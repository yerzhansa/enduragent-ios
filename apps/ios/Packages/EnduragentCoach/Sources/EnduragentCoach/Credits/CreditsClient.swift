import Foundation
import Security

public struct AthleteKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
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

public struct Credits: Sendable, Hashable, Comparable {
	public var units: Int
	public init(units: Int) {
		self.units = units
	}

	public static func < (lhs: Credits, rhs: Credits) -> Bool {
		lhs.units < rhs.units
	}
}

public struct CreditScale: Sendable, Equatable {
	public var creditsPerUsd: Int
	public init(creditsPerUsd: Int) {
		self.creditsPerUsd = creditsPerUsd
	}
}

public struct CreditPack: Identifiable, Sendable, Equatable {
	public var id: String
	public var credits: Credits
	public init(id: String, credits: Credits) {
		self.id = id
		self.credits = credits
	}
}

public struct PackCatalog: Sendable, Equatable {
	public var purchasesEnabled: Bool
	public var scale: CreditScale
	public var packs: [CreditPack]
	public init(purchasesEnabled: Bool, scale: CreditScale, packs: [CreditPack]) {
		self.purchasesEnabled = purchasesEnabled
		self.scale = scale
		self.packs = packs
	}
}

public enum GrantOutcome: Sendable, Equatable {
	case minted(Credits)
	case toppedUp(added: Credits)
	case alreadyGranted
}

public enum ClaimOutcome: Sendable, Equatable {
	case minted(creditsAdded: Credits)
	case toppedUp(creditsAdded: Credits)
	case alreadyClaimed
}

public struct Recovery: Sendable, Equatable {
	public var athleteId: UUID
	public var credits: Credits
	public init(athleteId: UUID, credits: Credits) {
		self.athleteId = athleteId
		self.credits = credits
	}
}

public struct CreditBalance: Sendable, Equatable {
	public var credits: Credits
	public init(credits: Credits) {
		self.credits = credits
	}
}

public enum CreditsFailure: Error, Sendable, Equatable {
	case banned
	case notOurBundle
	case wrongEnvironment
	case unknownPack
	case purchasesDisabled
	case noPurchaseToRecover
	case identityMismatch
	case rateLimited
	case unavailable
	case unexpectedResponse(status: Int)
	case noAthleteKey
}

public enum IntervalsCredential: Sendable, Equatable {
	case apiKey(String)
	case oauth(access: String, refresh: String)
}

public protocol SecretStore: Sendable {
	func appAccountToken() throws -> UUID
	func storeAppAccountToken(_ token: UUID) throws
	func openRouterKey() throws -> String?
	func storeOpenRouterKey(_ key: String) throws
	func intervalsCredential() throws -> IntervalsCredential?
	func storeIntervalsCredential(_ credential: IntervalsCredential) throws
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
}

public struct ICloudKeychainStore: SecretStore {
	package static let serviceName = "icu.enduragent.ios"
	package static let accessGroupName = "icu.enduragent.ios"

	private let backing: any SecretStoreBacking

	public init() {
		self.backing = SecItemSecretStoreBacking(service: Self.serviceName, accessGroup: nil)
	}

	package init(backing: any SecretStoreBacking) {
		self.backing = backing
	}

	public func appAccountToken() throws -> UUID {
		if let token = try readToken() {
			return token
		}
		let token = UUID()
		do {
			try backing.add(account: KeychainAccount.appAccountToken, data: Data(token.uuidString.utf8))
			return token
		} catch let error as KeychainStoreError where error.status == errSecDuplicateItem {
			if let existing = try readToken() {
				return existing
			}
			throw error
		}
	}

	public func storeAppAccountToken(_ token: UUID) throws {
		try write(account: KeychainAccount.appAccountToken, data: Data(token.uuidString.utf8))
	}

	public func openRouterKey() throws -> String? {
		try readString(account: KeychainAccount.openRouterKey)
	}

	public func storeOpenRouterKey(_ key: String) throws {
		try write(account: KeychainAccount.openRouterKey, data: Data(key.utf8))
	}

	public func intervalsCredential() throws -> IntervalsCredential? {
		guard let data = try backing.copy(account: KeychainAccount.intervalsCredential) else {
			return nil
		}
		return try JSONDecoder().decode(StoredIntervalsCredential.self, from: data).credential
	}

	public func storeIntervalsCredential(_ credential: IntervalsCredential) throws {
		let encoded = try JSONEncoder().encode(StoredIntervalsCredential(credential))
		try write(account: KeychainAccount.intervalsCredential, data: encoded)
	}

	private func readToken() throws -> UUID? {
		guard let raw = try readString(account: KeychainAccount.appAccountToken) else {
			return nil
		}
		guard let token = UUID(uuidString: raw) else {
			throw KeychainStoreError(status: errSecDecode)
		}
		return token
	}

	private func readString(account: String) throws -> String? {
		guard let data = try backing.copy(account: account) else {
			return nil
		}
		guard let string = String(data: data, encoding: .utf8) else {
			throw KeychainStoreError(status: errSecDecode)
		}
		return string
	}

	private func write(account: String, data: Data) throws {
		if try backing.copy(account: account) == nil {
			try backing.add(account: account, data: data)
		} else {
			try backing.update(account: account, data: data)
		}
	}
}

public protocol CreditsClient: Sendable {
	func grant(deviceCheck: Data) async throws -> GrantOutcome
	func claim(signedTransaction: String) async throws -> ClaimOutcome
	func recover(signedTransaction: String) async throws -> Recovery
	func catalog() async throws -> PackCatalog
	func balance(scale: CreditScale) async throws -> CreditBalance
}

public enum ClaimSettlement: Sendable, Equatable {
	case finish
	case recoverThenFinish

	public static func settlement(after outcome: ClaimOutcome, hasKey: Bool) -> ClaimSettlement {
		if outcome == .alreadyClaimed && !hasKey {
			return .recoverThenFinish
		}
		return .finish
	}
}

public struct PhoneCreditsClient: CreditsClient {
	private static let failures: [String: CreditsFailure] = [
		"banned": .banned,
		"not_our_bundle": .notOurBundle,
		"wrong_environment": .wrongEnvironment,
		"unknown_pack": .unknownPack,
		"purchases_disabled": .purchasesDisabled,
		"no_purchase_to_recover": .noPurchaseToRecover,
		"identity_mismatch": .identityMismatch,
		"rate_limited": .rateLimited,
		"unavailable": .unavailable,
	]
	private static let timeout: TimeInterval = 20

	private let secrets: any SecretStore
	private let workerBase: URL
	private let openRouterBase: URL
	private let session: URLSession

	public init(
		secrets: any SecretStore,
		workerBase: URL,
		openRouterBase: URL = URL(string: "https://openrouter.ai/api/v1")!,
		session: URLSession = .shared
	) {
		self.secrets = secrets
		self.workerBase = workerBase
		self.openRouterBase = openRouterBase
		self.session = session
	}

	public func grant(deviceCheck: Data) async throws -> GrantOutcome {
		let athleteId = try secrets.appAccountToken()
		let (status, data) = try await worker(
			path: "grant",
			method: "POST",
			body: GrantBody(
				athleteId: athleteId.uuidString.lowercased(),
				deviceCheckToken: deviceCheck.base64EncodedString()
			)
		)
		switch try decode(KindWire.self, from: data, status: status).kind {
		case "grantMinted":
			let wire = try decode(GrantMintedWire.self, from: data, status: status)
			try secrets.storeOpenRouterKey(wire.key)
			return .minted(Credits(units: wire.credits))
		case "grantToppedUp":
			let wire = try decode(GrantToppedUpWire.self, from: data, status: status)
			return .toppedUp(added: Credits(units: wire.added))
		case "grantAlreadyGranted":
			return .alreadyGranted
		default:
			throw CreditsFailure.unexpectedResponse(status: status)
		}
	}

	public func claim(signedTransaction: String) async throws -> ClaimOutcome {
		let (status, data) = try await worker(
			path: "claim",
			method: "POST",
			body: SignedTransactionBody(signedTransaction: signedTransaction)
		)
		switch try decode(KindWire.self, from: data, status: status).kind {
		case "claimMinted":
			let wire = try decode(ClaimMintedWire.self, from: data, status: status)
			try secrets.storeOpenRouterKey(wire.key)
			return .minted(creditsAdded: Credits(units: wire.creditsAdded))
		case "claimToppedUp":
			let wire = try decode(ClaimToppedUpWire.self, from: data, status: status)
			return .toppedUp(creditsAdded: Credits(units: wire.creditsAdded))
		case "claimAlreadyClaimed":
			return .alreadyClaimed
		default:
			throw CreditsFailure.unexpectedResponse(status: status)
		}
	}

	public func recover(signedTransaction: String) async throws -> Recovery {
		let (status, data) = try await worker(
			path: "recover",
			method: "POST",
			body: SignedTransactionBody(signedTransaction: signedTransaction)
		)
		guard try decode(KindWire.self, from: data, status: status).kind == "recovered" else {
			throw CreditsFailure.unexpectedResponse(status: status)
		}
		let wire = try decode(RecoveredWire.self, from: data, status: status)
		try secrets.storeOpenRouterKey(wire.key)
		try secrets.storeAppAccountToken(wire.athleteId)
		return Recovery(athleteId: wire.athleteId, credits: Credits(units: wire.credits))
	}

	public func catalog() async throws -> PackCatalog {
		let (status, data) = try await send(
			url: workerBase.appending(path: "catalog"),
			method: "GET",
			body: nil,
			authorization: nil
		)
		let wire = try decode(CatalogWire.self, from: data, status: status)
		return PackCatalog(
			purchasesEnabled: wire.purchasesEnabled,
			scale: CreditScale(creditsPerUsd: wire.creditsPerUsd),
			packs: wire.packs.map { CreditPack(id: $0.productId, credits: Credits(units: $0.credits)) }
		)
	}

	public func balance(scale: CreditScale) async throws -> CreditBalance {
		guard let key = try secrets.openRouterKey() else {
			throw CreditsFailure.noAthleteKey
		}
		let (status, data) = try await send(
			url: openRouterBase.appending(path: "key"),
			method: "GET",
			body: nil,
			authorization: "Bearer \(key)"
		)
		let remaining = try decode(OpenRouterKeyWire.self, from: data, status: status).data.limit_remaining ?? 0
		let units = Int(floor(remaining * Double(scale.creditsPerUsd)))
		return CreditBalance(credits: Credits(units: max(0, units)))
	}

	private func worker(path: String, method: String, body: some Encodable) async throws -> (status: Int, data: Data) {
		try await send(
			url: workerBase.appending(path: path),
			method: method,
			body: try JSONEncoder().encode(body),
			authorization: nil
		)
	}

	private func send(url: URL, method: String, body: Data?, authorization: String?) async throws -> (status: Int, data: Data) {
		var request = URLRequest(url: url, timeoutInterval: Self.timeout)
		request.httpMethod = method
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if let authorization {
			request.setValue(authorization, forHTTPHeaderField: "Authorization")
		}
		request.httpBody = body
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw CreditsFailure.unexpectedResponse(status: 0)
		}
		guard (200..<300).contains(http.statusCode) else {
			if let wire = try? JSONDecoder().decode(ErrorWire.self, from: data),
				let failure = Self.failures[wire.error]
			{
				throw failure
			}
			throw CreditsFailure.unexpectedResponse(status: http.statusCode)
		}
		return (http.statusCode, data)
	}

	private func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			throw CreditsFailure.unexpectedResponse(status: status)
		}
	}
}

private struct GrantBody: Encodable {
	var athleteId: String
	var deviceCheckToken: String
}

private struct SignedTransactionBody: Encodable {
	var signedTransaction: String
}

private struct ErrorWire: Decodable {
	var error: String
}

private struct KindWire: Decodable {
	var kind: String
}

private struct GrantMintedWire: Decodable {
	var key: String
	var credits: Int
}

private struct GrantToppedUpWire: Decodable {
	var added: Int
}

private struct ClaimMintedWire: Decodable {
	var key: String
	var creditsAdded: Int
}

private struct ClaimToppedUpWire: Decodable {
	var creditsAdded: Int
}

private struct RecoveredWire: Decodable {
	var athleteId: UUID
	var key: String
	var credits: Int
}

private struct CatalogWire: Decodable {
	var purchasesEnabled: Bool
	var creditsPerUsd: Int
	var packs: [CatalogPackWire]
}

private struct CatalogPackWire: Decodable {
	var productId: String
	var credits: Int
}

private struct OpenRouterKeyWire: Decodable {
	var data: OpenRouterKeyDataWire
}

private struct OpenRouterKeyDataWire: Decodable {
	var limit_remaining: Double?
}

private enum KeychainAccount {
	static let appAccountToken = "appAccountToken"
	static let openRouterKey = "openRouterKey"
	static let intervalsCredential = "intervalsCredential"
}

private enum StoredIntervalsCredential: Codable {
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

private struct SecItemSecretStoreBacking: SecretStoreBacking {
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

	private func baseQuery(account: String) -> [String: Any] {
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
