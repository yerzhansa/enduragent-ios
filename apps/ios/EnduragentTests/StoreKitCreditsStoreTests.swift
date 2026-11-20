import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import StoreKit
import StoreKitTest
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized) final class StoreKitCreditsStoreTests {
	private static let small = "icu.enduragent.app.credits.small"
	private let session: SKTestSession
	private let store = StoreKitCreditsStore()

	init() throws {
		let url = try #require(
			Bundle(for: StoreKitCreditsStoreTests.self).url(
				forResource: "CreditsPacks", withExtension: "storekit"))
		session = try SKTestSession(contentsOf: url)
		session.resetToDefaultState()
		session.disableDialogs = true
		session.clearTransactions()
	}

	@Test func aPurchaseCarriesTheCreditsIdAndFinishes() async throws {
		#expect(
			try await store.displayPrices(for: [Self.small, "icu.enduragent.app.credits.large"])
				== [Self.small: "$4.99", "icu.enduragent.app.credits.large": "$19.99"])
		let token = UUID()
		let purchase = try purchased(try await store.purchase(Self.small, appAccountToken: token))
		#expect(purchase.appAccountToken == token)
		#expect(!purchase.isRefunded)
		#expect(try await unfinishedIDs() == [purchase.id])
		await store.finish(purchase.id)
		#expect(try await unfinishedIDs().isEmpty)
	}

	@Test func anUnfinishedPurchaseIsHandedBackToTheNextListener() async throws {
		let token = UUID()
		let purchase = try purchased(try await store.purchase(Self.small, appAccountToken: token))
		let handedBack = try await next(from: store.purchases())
		#expect(handedBack.id == purchase.id)
		#expect(handedBack.appAccountToken == token)
		#expect(!handedBack.isRefunded)
	}

	@Test func anAskToBuyPurchaseArrivesWhenApproved() async throws {
		session.askToBuyEnabled = true
		let token = UUID()
		#expect(try await store.purchase(Self.small, appAccountToken: token) == .pending)
		let stream = store.purchases()
		let waiting = try #require(
			session.allTransactions().first { $0.pendingAskToBuyConfirmation })
		try session.approveAskToBuyTransaction(identifier: waiting.identifier)
		let approved = try await next(from: stream)
		#expect(approved.appAccountToken == token)
		#expect(!approved.isRefunded)
	}

	@Test func aPurchaseAppleRefundedBeforeItWasFinishedIsHandedBackAsRefunded() async throws {
		let purchase = try purchased(
			try await store.purchase(Self.small, appAccountToken: UUID()))
		try session.refundTransaction(identifier: UInt(purchase.id))
		try await until {
			let handedBack = try await next(from: store.purchases())
			return handedBack.id == purchase.id && handedBack.isRefunded
		}
	}

	private func purchased(_ answer: StorePurchase) throws -> CreditsPurchase {
		guard case .purchased(let purchase) = answer else {
			throw StoreTestFailure.notPurchased(answer)
		}
		return purchase
	}

	private func unfinishedIDs() async throws -> [UInt64] {
		var ids: [UInt64] = []
		for await verification in Transaction.unfinished {
			ids.append(verification.unsafePayloadValue.id)
		}
		return ids
	}

	private func next(from stream: AsyncStream<CreditsPurchase>) async throws -> CreditsPurchase {
		try await withThrowingTaskGroup(of: CreditsPurchase?.self) { group in
			group.addTask {
				for await purchase in stream { return purchase }
				return nil
			}
			group.addTask {
				try await Task.sleep(for: TestWaitLimit.hangGuard.duration)
				return nil
			}
			let first = try await group.next()
			group.cancelAll()
			guard let purchase = first.flatMap({ $0 }) else {
				throw StoreTestFailure.nothingDelivered
			}
			return purchase
		}
	}
}

private enum StoreTestFailure: Error {
	case notPurchased(StorePurchase)
	case nothingDelivered
}
