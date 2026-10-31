import Synchronization

package final class CountingHost: ExecutionHost {
	private let base: any ExecutionHost
	private let open = Mutex(0)

	package init(_ base: any ExecutionHost) {
		self.base = base
	}

	package var isIdle: Bool { open.withLock { $0 == 0 } }

	package func beginLease(
		_ request: LeaseRequest, onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease {
		open.withLock { $0 += 1 }
		return CountedLease(await base.beginLease(request, onExpiry: onExpiry), host: self)
	}

	fileprivate func release() {
		open.withLock { $0 -= 1 }
	}
}

private final class CountedLease: ExecutionLease {
	private let base: any ExecutionLease
	private let host: Mutex<CountingHost?>

	init(_ base: any ExecutionLease, host: CountingHost) {
		self.base = base
		self.host = Mutex(host)
	}

	var kind: LeaseKind { base.kind }

	func end(_ ending: LeaseEnding) async {
		await base.end(ending)
		host.withLock { host in
			host?.release()
			host = nil
		}
	}
}
