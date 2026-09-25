import Foundation

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
			try backing.add(
				account: KeychainAccount.appAccountToken, data: Data(token.uuidString.utf8))
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
		openRouterBase: URL = OpenRouterTransport.apiBase,
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
			packs: wire.packs.map {
				CreditPack(id: $0.productId, credits: Credits(units: $0.credits))
			}
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
		let remaining =
			try decode(OpenRouterKeyWire.self, from: data, status: status).data.limit_remaining ?? 0
		let units = Int(floor(remaining * Double(scale.creditsPerUsd)))
		return CreditBalance(credits: Credits(units: max(0, units)))
	}

	private func worker(path: String, method: String, body: some Encodable) async throws -> (
		status: Int, data: Data
	) {
		try await send(
			url: workerBase.appending(path: path),
			method: method,
			body: try JSONEncoder().encode(body),
			authorization: nil
		)
	}

	private func send(url: URL, method: String, body: Data?, authorization: String?) async throws
		-> (status: Int, data: Data)
	{
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
			do {
				let wire = try JSONDecoder().decode(ErrorWire.self, from: data)
				if let failure = Self.failures[wire.error] {
					throw failure
				}
			} catch is DecodingError {}
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
