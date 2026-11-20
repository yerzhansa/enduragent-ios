import EnduragentCoach
import Foundation
import Synchronization

public enum FakeStoreAnswer: Sendable, Equatable {
	case purchased
	case pending
	case canceled
	case failed
}

public enum FakeStoreFailure: Error, Sendable, Equatable {
	case purchaseFailed
	case refundFailed
	case pricesUnavailable
}

public final class FakeCreditsStore: CreditsStore {
	private struct State {
		var prices: Result<[String: String], FakeStoreFailure>
		var answer: FakeStoreAnswer = .purchased
		var refundAnswer: Result<RefundRequest, FakeStoreFailure> = .success(.submitted)
		var nextID: UInt64 = 1
		var bought: [String] = []
		var unfinished: [CreditsPurchase] = []
		var finished: [CreditsPurchase.ID] = []
		var refundRequests: [CreditsPurchase.ID] = []
		var listeners: [AsyncStream<CreditsPurchase>.Continuation] = []
	}

	private let state: Mutex<State>
	private let purchaseDate: Date

	public init(
		prices: [String: String], purchaseDate: Date = Date(timeIntervalSince1970: 897_897_600)
	) {
		state = Mutex(State(prices: .success(prices)))
		self.purchaseDate = purchaseDate
	}

	public var prices: Result<[String: String], FakeStoreFailure> {
		get { state.withLock { $0.prices } }
		set { state.withLock { $0.prices = newValue } }
	}

	public var answer: FakeStoreAnswer {
		get { state.withLock { $0.answer } }
		set { state.withLock { $0.answer = newValue } }
	}

	public var refundAnswer: Result<RefundRequest, FakeStoreFailure> {
		get { state.withLock { $0.refundAnswer } }
		set { state.withLock { $0.refundAnswer = newValue } }
	}

	public var bought: [String] { state.withLock { $0.bought } }
	public var unfinished: [CreditsPurchase] { state.withLock { $0.unfinished } }
	public var finished: [CreditsPurchase.ID] { state.withLock { $0.finished } }
	public var refundRequests: [CreditsPurchase.ID] { state.withLock { $0.refundRequests } }

	public func displayPrices(for productIDs: [String]) async throws -> [String: String] {
		try state.withLock { $0.prices }.get().filter { productIDs.contains($0.key) }
	}

	@MainActor
	public func purchase(_ productID: String, appAccountToken: UUID) async throws -> StorePurchase {
		let answer = state.withLock { current in
			current.bought.append(productID)
			return current.answer
		}
		switch answer {
		case .purchased:
			return .purchased(record(productID, appAccountToken: appAccountToken))
		case .pending:
			return .pending
		case .canceled:
			return .canceled
		case .failed:
			throw FakeStoreFailure.purchaseFailed
		}
	}

	public func approve(_ productID: String, appAccountToken: UUID) {
		deliver(record(productID, appAccountToken: appAccountToken))
	}

	public func refund(_ purchase: CreditsPurchase) {
		deliver(
			CreditsPurchase(
				id: purchase.id, signedTransaction: purchase.signedTransaction,
				appAccountToken: purchase.appAccountToken, purchaseDate: purchase.purchaseDate,
				isRefunded: true))
	}

	public func purchases() -> AsyncStream<CreditsPurchase> {
		let (stream, continuation) = AsyncStream.makeStream(of: CreditsPurchase.self)
		let handedBack = state.withLock { current in
			current.listeners.append(continuation)
			return current.unfinished
		}
		for purchase in handedBack { continuation.yield(purchase) }
		return stream
	}

	public func finish(_ purchase: CreditsPurchase.ID) async {
		state.withLock { current in
			current.finished.append(purchase)
			current.unfinished.removeAll { $0.id == purchase }
		}
	}

	public func newestSignedTransaction(after purchase: CreditsPurchase) async -> String {
		purchase.signedTransaction
	}

	@MainActor
	public func requestRefund(for purchase: CreditsPurchase.ID) async throws -> RefundRequest {
		try state.withLock { current in
			current.refundRequests.append(purchase)
			return current.refundAnswer
		}.get()
	}

	private func record(_ productID: String, appAccountToken: UUID) -> CreditsPurchase {
		state.withLock { current in
			let purchase = CreditsPurchase(
				id: current.nextID, signedTransaction: "fake.signed.\(productID)",
				appAccountToken: appAccountToken, purchaseDate: purchaseDate, isRefunded: false)
			current.nextID += 1
			current.unfinished.append(purchase)
			return purchase
		}
	}

	private func deliver(_ purchase: CreditsPurchase) {
		let listeners = state.withLock { current in
			current.unfinished.removeAll { $0.id == purchase.id }
			current.unfinished.append(purchase)
			return current.listeners
		}
		for listener in listeners { listener.yield(purchase) }
	}
}
