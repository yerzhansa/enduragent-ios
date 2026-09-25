import EnduragentCoach
import Foundation
import StoreKit

enum StoreKitPurchaseFailure: Error {
	case unverified
	case userCancelled
	case pending
}

@MainActor
final class StoreKitPurchaseCoordinator {
	private let credits: any CreditsClient
	private let secrets: any SecretStore
	private var updatesTask: Task<Void, Never>?

	init(credits: any CreditsClient, secrets: any SecretStore) {
		self.credits = credits
		self.secrets = secrets
		updatesTask = Task { [weak self] in
			for await update in Transaction.updates {
				guard let self else { return }
				_ = try? await self.settle(update)
			}
		}
	}

	deinit {
		updatesTask?.cancel()
	}

	func purchase(_ product: Product) async throws -> ClaimOutcome {
		let result = try await product.purchase(options: [
			.appAccountToken(try secrets.appAccountToken())
		])
		switch result {
		case .success(let verification):
			return try await settle(verification)
		case .userCancelled:
			throw StoreKitPurchaseFailure.userCancelled
		case .pending:
			throw StoreKitPurchaseFailure.pending
		@unknown default:
			throw CreditsFailure.unavailable
		}
	}

	func settle(_ verification: VerificationResult<Transaction>) async throws -> ClaimOutcome {
		guard case .verified(let tx) = verification else {
			throw StoreKitPurchaseFailure.unverified
		}
		let outcome = try await credits.claim(signedTransaction: verification.jwsRepresentation)
		let hasKey = try secrets.openRouterKey() != nil
		switch ClaimSettlement.settlement(after: outcome, hasKey: hasKey) {
		case .finish:
			await tx.finish()
			return outcome
		case .recoverThenFinish:
			let jws = await newestPurchaseJWS(fallback: verification)
			_ = try await credits.recover(signedTransaction: jws)
			await tx.finish()
			return outcome
		}
	}

	private func newestPurchaseJWS(fallback: VerificationResult<Transaction>) async -> String {
		var newestDate: Date?
		var newestJWS = fallback.jwsRepresentation
		if case .verified(let tx) = fallback {
			newestDate = tx.purchaseDate
		}
		for await item in Transaction.all {
			guard case .verified(let candidate) = item else { continue }
			if let newestDate, candidate.purchaseDate <= newestDate {
				continue
			}
			newestDate = candidate.purchaseDate
			newestJWS = item.jwsRepresentation
		}
		return newestJWS
	}
}
