import Foundation

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
