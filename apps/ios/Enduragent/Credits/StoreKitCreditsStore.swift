import EnduragentCoach
import Foundation
import StoreKit
import UIKit

enum StoreKitCreditsStoreFailure: Error, Equatable {
	case productUnavailable(String)
	case noActiveScene
	case unknownAnswer
}

struct StoreKitCreditsStore: CreditsStore {
	func displayPrices(for productIDs: [String]) async throws -> [String: String] {
		let products = try await Product.products(for: productIDs)
		return Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0.displayPrice) })
	}

	@MainActor
	func purchase(_ productID: String, appAccountToken: UUID) async throws -> StorePurchase {
		guard let product = try await Product.products(for: [productID]).first else {
			throw StoreKitCreditsStoreFailure.productUnavailable(productID)
		}
		switch try await product.purchase(options: [.appAccountToken(appAccountToken)]) {
		case .success(let verification):
			return .purchased(CreditsPurchase(verification))
		case .pending:
			return .pending
		case .userCancelled:
			return .canceled
		@unknown default:
			throw StoreKitCreditsStoreFailure.unknownAnswer
		}
	}

	func purchases() -> AsyncStream<CreditsPurchase> {
		AsyncStream { continuation in
			let listener = Task {
				var handedBack = Set<CreditsPurchase.ID>()
				for await verification in Transaction.unfinished {
					let purchase = CreditsPurchase(verification)
					if !purchase.isRefunded { handedBack.insert(purchase.id) }
					continuation.yield(purchase)
				}
				for await verification in Transaction.updates {
					let purchase = CreditsPurchase(verification)
					if !purchase.isRefunded, handedBack.remove(purchase.id) != nil { continue }
					continuation.yield(purchase)
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in listener.cancel() }
		}
	}

	func finish(_ purchase: CreditsPurchase.ID) async {
		for await verification in Transaction.unfinished
		where verification.unsafePayloadValue.id == purchase {
			await verification.unsafePayloadValue.finish()
		}
	}

	func newestSignedTransaction(after purchase: CreditsPurchase) async -> String {
		var newest = (date: purchase.purchaseDate, signed: purchase.signedTransaction)
		for await verification in Transaction.all {
			let candidate = verification.unsafePayloadValue
			guard candidate.purchaseDate > newest.date else { continue }
			newest = (candidate.purchaseDate, verification.jwsRepresentation)
		}
		return newest.signed
	}

	@MainActor
	func requestRefund(for purchase: CreditsPurchase.ID) async throws -> RefundRequest {
		switch try await Transaction.beginRefundRequest(for: purchase, in: try activeScene()) {
		case .success:
			return .submitted
		case .userCancelled:
			return .canceled
		@unknown default:
			throw StoreKitCreditsStoreFailure.unknownAnswer
		}
	}

	@MainActor
	private func activeScene() throws -> UIWindowScene {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else {
			throw StoreKitCreditsStoreFailure.noActiveScene
		}
		return scene
	}
}

extension CreditsPurchase {
	fileprivate init(_ verification: VerificationResult<Transaction>) {
		let transaction = verification.unsafePayloadValue
		self.init(
			id: transaction.id, signedTransaction: verification.jwsRepresentation,
			appAccountToken: transaction.appAccountToken, purchaseDate: transaction.purchaseDate,
			isRefunded: transaction.revocationDate != nil)
	}
}
