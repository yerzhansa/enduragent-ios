import Foundation

public struct CreditsOffer: Identifiable, Sendable, Equatable {
	public let pack: CreditPack
	public let displayPrice: String
	public var id: String { pack.id }

	public init(pack: CreditPack, displayPrice: String) {
		self.pack = pack
		self.displayPrice = displayPrice
	}
}

public struct CreditsPurchase: Identifiable, Sendable, Equatable {
	public let id: UInt64
	public let signedTransaction: String
	public let appAccountToken: UUID?
	public let purchaseDate: Date
	public let isRefunded: Bool

	public init(
		id: UInt64, signedTransaction: String, appAccountToken: UUID?, purchaseDate: Date,
		isRefunded: Bool
	) {
		self.id = id
		self.signedTransaction = signedTransaction
		self.appAccountToken = appAccountToken
		self.purchaseDate = purchaseDate
		self.isRefunded = isRefunded
	}
}

public enum StorePurchase: Sendable, Equatable {
	case purchased(CreditsPurchase)
	case pending
	case canceled
}

public enum RefundRequest: Sendable, Equatable {
	case submitted
	case canceled
}

public protocol CreditsStore: Sendable {
	func displayPrices(for productIDs: [String]) async throws -> [String: String]
	@MainActor func purchase(_ productID: String, appAccountToken: UUID) async throws
		-> StorePurchase
	func purchases() -> AsyncStream<CreditsPurchase>
	func finish(_ purchase: CreditsPurchase.ID) async
	func newestSignedTransaction(after purchase: CreditsPurchase) async -> String
	@MainActor func requestRefund(for purchase: CreditsPurchase.ID) async throws -> RefundRequest
}

package enum PurchaseStep: String, Sendable, Equatable, CaseIterable {
	case offers
	case appStore
	case claimLater
	case claimRefused
	case refund
}

enum CreditsSettlement: Equatable {
	case added(Credits, switchedToCredits: Bool)
	case alreadyAdded
	case refunded
	case notAddedYet
	case refused(CreditsPurchase.ID)

	var finishesPurchase: Bool { self != .notAddedYet }

	var notice: AthleteNotice? {
		switch self {
		case .added(let added, let switched):
			AthleteNotice(
				key: switched
					? Catalog.creditsPurchaseAddedSwitched : Catalog.onboardingStarterAdded,
				count: added.units, vars: ["formattedCount": .integer(added.units)], actions: [])
		case .alreadyAdded, .refunded:
			nil
		case .notAddedYet:
			AthleteNotice(key: Catalog.creditsPurchaseNotAdded, actions: [])
		case .refused(let purchase):
			AthleteNotice(
				key: Catalog.creditsPurchaseRefused, actions: [.askAppleForRefund(purchase)])
		}
	}
}

extension CreditsFailure {
	var refusesPurchase: Bool {
		switch self {
		case .banned, .athleteDeleted, .identityMismatch, .notOurBundle, .wrongEnvironment:
			true
		case .unknownPack, .noPurchaseToRecover, .accountChanged, .rateLimited, .unavailable,
			.unexpectedResponse, .noAthleteKey, .unauthorized:
			false
		}
	}
}

extension AthleteNotice {
	public static let creditsNotForSale = AthleteNotice(
		key: Catalog.creditsPurchaseUnavailable, actions: [])
}

extension Coach {
	public func creditsOffers(in store: any CreditsStore) async -> [CreditsOffer] {
		do {
			let catalog = try await credits.catalog()
			guard catalog.purchasesEnabled else { return [] }
			let prices = try await store.displayPrices(for: catalog.packs.map(\.id))
			return catalog.packs.compactMap { pack in
				prices[pack.id].map { CreditsOffer(pack: pack, displayPrice: $0) }
			}
		} catch {
			diagnostics.record(.purchaseNotFinished(.offers, FailureCode(error)))
			return []
		}
	}

	public func buyCredits(_ offer: CreditsOffer, in store: any CreditsStore) async
		-> AthleteNotice?
	{
		let token: UUID
		do {
			token = try await prepareCreditsPurchase()
		} catch {
			return AthleteNotice.credits(failure: error)
		}
		let answer: StorePurchase
		do {
			answer = try await store.purchase(offer.id, appAccountToken: token)
		} catch {
			diagnostics.record(.purchaseNotFinished(.appStore, FailureCode(error)))
			return AthleteNotice(key: Catalog.creditsPurchaseFailed, actions: [])
		}
		switch answer {
		case .purchased(let purchase):
			return await settleCreditsPurchase(purchase, in: store)
		case .pending:
			return AthleteNotice(key: Catalog.creditsPurchasePending, actions: [])
		case .canceled:
			return nil
		}
	}

	public func settleCreditsPurchase(_ purchase: CreditsPurchase, in store: any CreditsStore)
		async -> AthleteNotice?
	{
		let settlement = await settlement(of: purchase, in: store)
		if settlement.finishesPurchase { await store.finish(purchase.id) }
		return settlement.notice
	}

	public func requestCreditsRefund(for purchase: CreditsPurchase.ID, in store: any CreditsStore)
		async -> RefundRequest?
	{
		do {
			return try await store.requestRefund(for: purchase)
		} catch {
			diagnostics.record(.purchaseNotFinished(.refund, FailureCode(error)))
			return nil
		}
	}

	private func settlement(of purchase: CreditsPurchase, in store: any CreditsStore) async
		-> CreditsSettlement
	{
		guard !purchase.isRefunded else { return .refunded }
		do {
			guard let token = purchase.appAccountToken else {
				throw CreditsFailure.identityMismatch
			}
			let hasKey = try await creditsIdentity().hasCreditsKey
			let outcome = try await credits.claim(
				signedTransaction: purchase.signedTransaction, appAccountToken: token)
			if ClaimSettlement.settlement(after: outcome, hasKey: hasKey) == .recoverThenFinish {
				do {
					_ = try await credits.recover(
						signedTransaction: await store.newestSignedTransaction(after: purchase))
				} catch {
					diagnostics.record(.purchaseNotFinished(.claimLater, FailureCode(error)))
					return .notAddedYet
				}
			}
			switch outcome {
			case .minted(let added), .toppedUp(let added):
				guard added.units > 0 else { return .refunded }
				return .added(added, switchedToCredits: await switchToCredits())
			case .alreadyClaimed:
				return .alreadyAdded
			}
		} catch let failure as CreditsFailure where failure.refusesPurchase {
			diagnostics.record(.purchaseNotFinished(.claimRefused, FailureCode(failure)))
			return .refused(purchase.id)
		} catch {
			diagnostics.record(.purchaseNotFinished(.claimLater, FailureCode(error)))
			return .notAddedYet
		}
	}

	private func switchToCredits() async -> Bool {
		guard await preferences.accessStatus().savedMethod == .openRouterAccount else {
			return false
		}
		guard case .replaced = await changeModelAccess(.useCredits) else { return false }
		return true
	}
}
