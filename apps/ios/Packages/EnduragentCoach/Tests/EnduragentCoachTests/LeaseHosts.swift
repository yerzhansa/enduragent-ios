import Foundation
import Synchronization

@testable import EnduragentCoach

final class KeepingHost: ExecutionHost {
	private let inner = ImmediateExecutionHost()
	private let expiries = Mutex<[@Sendable (ExpiryCause) async -> Void]>([])

	func beginLease(
		_ request: LeaseRequest, onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease {
		expiries.withLock { $0.append(onExpiry) }
		return await inner.beginLease(request, onExpiry: onExpiry)
	}

	func expire(lease index: Int, _ cause: ExpiryCause) async {
		let handler = expiries.withLock { $0[index] }
		await handler(cause)
	}
}

final class GraceOnlyHost: ExecutionHost {
	private let inner = ImmediateExecutionHost()

	func beginLease(
		_ request: LeaseRequest, onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease {
		GraceLease(inner: await inner.beginLease(request, onExpiry: onExpiry))
	}
}

private struct GraceLease: ExecutionLease {
	let inner: any ExecutionLease
	let kind: LeaseKind = .gracePeriodOnly

	func report(_ progress: LeaseProgress) async {
		await inner.report(progress)
	}

	func end(_ ending: LeaseEnding) async {
		await inner.end(ending)
	}
}
