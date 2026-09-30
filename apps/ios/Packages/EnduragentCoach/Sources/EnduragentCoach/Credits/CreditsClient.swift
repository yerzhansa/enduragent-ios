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
	case accountChanged
	case rateLimited
	case unavailable
	case unexpectedResponse(status: Int)
	case noAthleteKey
}

public struct CreditsService: Sendable {
	package let makeClient: @Sendable (CredentialVault) -> any CreditsClient

	package init(makeClient: @escaping @Sendable (CredentialVault) -> any CreditsClient) {
		self.makeClient = makeClient
	}

	public static func worker(_ base: URL) -> CreditsService {
		CreditsService { PhoneCreditsClient(vault: $0, workerBase: base) }
	}
}

public protocol CreditsClient: Sendable {
	func grant(deviceCheck: Data) async throws -> GrantOutcome
	func claim(signedTransaction: String, appAccountToken: UUID) async throws -> ClaimOutcome
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

package struct PhoneCreditsClient: CreditsClient {
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

	private let vault: CredentialVault
	private let workerBase: URL
	private let openRouterBase: URL
	private let session: URLSession

	package init(
		vault: CredentialVault,
		workerBase: URL,
		openRouterBase: URL = ModelService.openRouterAPI,
		session: URLSession? = nil
	) {
		self.vault = vault
		self.workerBase = workerBase
		self.openRouterBase = openRouterBase
		self.session = session ?? ephemeralSession(requestTimeout: Self.timeout)
	}

	package func grant(deviceCheck: Data) async throws -> GrantOutcome {
		let athleteId = try await vault.prepareCreditsAccount()
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
			try await vault.storeCreditsKey(
				try mintedKey(wire.key, status: status), mintedFor: athleteId)
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

	package func claim(signedTransaction: String, appAccountToken: UUID) async throws
		-> ClaimOutcome
	{
		let (status, data) = try await worker(
			path: "claim",
			method: "POST",
			body: SignedTransactionBody(signedTransaction: signedTransaction)
		)
		switch try decode(KindWire.self, from: data, status: status).kind {
		case "claimMinted":
			let wire = try decode(ClaimMintedWire.self, from: data, status: status)
			try await vault.storeCreditsKey(
				try mintedKey(wire.key, status: status), mintedFor: appAccountToken)
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

	package func recover(signedTransaction: String) async throws -> Recovery {
		let (status, data) = try await worker(
			path: "recover",
			method: "POST",
			body: SignedTransactionBody(signedTransaction: signedTransaction)
		)
		guard try decode(KindWire.self, from: data, status: status).kind == "recovered" else {
			throw CreditsFailure.unexpectedResponse(status: status)
		}
		let wire = try decode(RecoveredWire.self, from: data, status: status)
		try await vault.storeRecovery(
			key: try mintedKey(wire.key, status: status), appAccountToken: wire.athleteId)
		return Recovery(athleteId: wire.athleteId, credits: Credits(units: wire.credits))
	}

	package func catalog() async throws -> PackCatalog {
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

	package func balance(scale: CreditScale) async throws -> CreditBalance {
		guard let key = try await vault.creditsKey()?.value else {
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
		guard let units = wholeInt(floor(remaining * Double(scale.creditsPerUsd))) else {
			throw CreditsFailure.unexpectedResponse(status: status)
		}
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
			} catch is DecodingError {
				throw CreditsFailure.unexpectedResponse(status: http.statusCode)
			}
			throw CreditsFailure.unexpectedResponse(status: http.statusCode)
		}
		return (http.statusCode, data)
	}

	private func mintedKey(_ raw: String, status: Int) throws -> NonEmptySecret {
		guard let key = NonEmptySecret(raw) else {
			throw CreditsFailure.unexpectedResponse(status: status)
		}
		return key
	}

	private func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			throw CreditsFailure.unexpectedResponse(status: status)
		}
	}
}
