import Foundation
import Synchronization

public enum FakeCreditsCall: Sendable, Equatable {
	case grant
	case claim(transactionLength: Int)
	case recover(transactionLength: Int)
	case catalog
	case balance
}

public final class FakeCreditsClient: CreditsClient, @unchecked Sendable {
	private struct State {
		var grantResult: Result<GrantOutcome, CreditsFailure>
		var claimResult: Result<ClaimOutcome, CreditsFailure>
		var recoverResult: Result<Recovery, CreditsFailure>
		var catalogResult: Result<PackCatalog, CreditsFailure>
		var balanceResult: Result<CreditBalance, CreditsFailure>
		var calls: [FakeCreditsCall]
	}

	private let state: Mutex<State>

	public var grantResult: Result<GrantOutcome, CreditsFailure> {
		get { state.withLock { $0.grantResult } }
		set { state.withLock { $0.grantResult = newValue } }
	}

	public var claimResult: Result<ClaimOutcome, CreditsFailure> {
		get { state.withLock { $0.claimResult } }
		set { state.withLock { $0.claimResult = newValue } }
	}

	public var recoverResult: Result<Recovery, CreditsFailure> {
		get { state.withLock { $0.recoverResult } }
		set { state.withLock { $0.recoverResult = newValue } }
	}

	public var catalogResult: Result<PackCatalog, CreditsFailure> {
		get { state.withLock { $0.catalogResult } }
		set { state.withLock { $0.catalogResult = newValue } }
	}

	public var balanceResult: Result<CreditBalance, CreditsFailure> {
		get { state.withLock { $0.balanceResult } }
		set { state.withLock { $0.balanceResult = newValue } }
	}

	public var calls: [FakeCreditsCall] {
		state.withLock { $0.calls }
	}

	public init() {
		self.state = Mutex(
			State(
				grantResult: .failure(.unavailable),
				claimResult: .failure(.unavailable),
				recoverResult: .failure(.unavailable),
				catalogResult: .failure(.unavailable),
				balanceResult: .failure(.unavailable),
				calls: []
			)
		)
	}

	public func grant(deviceCheck _: Data) async throws -> GrantOutcome {
		let result = state.withLock { current in
			current.calls.append(.grant)
			return current.grantResult
		}
		return try result.get()
	}

	public func claim(signedTransaction: String) async throws -> ClaimOutcome {
		let result = state.withLock { current in
			current.calls.append(.claim(transactionLength: signedTransaction.count))
			return current.claimResult
		}
		return try result.get()
	}

	public func recover(signedTransaction: String) async throws -> Recovery {
		let result = state.withLock { current in
			current.calls.append(.recover(transactionLength: signedTransaction.count))
			return current.recoverResult
		}
		return try result.get()
	}

	public func catalog() async throws -> PackCatalog {
		let result = state.withLock { current in
			current.calls.append(.catalog)
			return current.catalogResult
		}
		return try result.get()
	}

	public func balance(scale _: CreditScale) async throws -> CreditBalance {
		let result = state.withLock { current in
			current.calls.append(.balance)
			return current.balanceResult
		}
		return try result.get()
	}
}
