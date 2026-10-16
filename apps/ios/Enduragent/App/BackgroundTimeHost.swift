import EnduragentCoach
import UIKit

@MainActor
protocol BackgroundSystem: AnyObject {
	func beginGrace(named name: String, expiration: @escaping () -> Void)
		-> UIBackgroundTaskIdentifier
	func endGrace(_ identifier: UIBackgroundTaskIdentifier)
}

@MainActor
final class BackgroundTimeHost: ExecutionHost {
	static let keptLeases = 50

	private let bundleIdentifier: String
	let system: any BackgroundSystem
	private(set) var leases: [LeaseRecord] = []

	init(bundleIdentifier: String, system: any BackgroundSystem) {
		self.bundleIdentifier = bundleIdentifier
		self.system = system
	}

	func beginLease(
		_ request: LeaseRequest, onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease {
		let identifier = "\(bundleIdentifier).coach.\(ULID.generate(at: Date()).rawValue)"
		let lease = BackgroundTimeLease(identifier, host: self, onExpiry: onExpiry)
		leases.append(LeaseRecord(id: identifier, request: request, kind: lease.kind))
		leases.removeFirst(max(0, leases.count - Self.keptLeases))
		lease.beginGrace()
		return lease
	}

	func update(_ identifier: String, _ change: (inout LeaseRecord) -> Void) {
		guard let index = leases.firstIndex(where: { $0.id == identifier }) else { return }
		change(&leases[index])
	}
}

@MainActor
final class BackgroundTimeLease: ExecutionLease {
	nonisolated let kind = LeaseKind.gracePeriodOnly
	private let identifier: String
	private let host: BackgroundTimeHost
	private let onExpiry: @Sendable (ExpiryCause) async -> Void
	private var state = State.active
	private var grace = UIBackgroundTaskIdentifier.invalid

	private enum State {
		case active
		case settling
		case ended
	}

	init(
		_ identifier: String, host: BackgroundTimeHost,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) {
		self.identifier = identifier
		self.host = host
		self.onExpiry = onExpiry
	}

	func beginGrace() {
		grace = host.system.beginGrace(named: identifier) {
			Task { await self.expire() }
		}
	}

	func end(_ ending: LeaseEnding) async {
		if case .settling = state, case .interrupted = ending {
			close(ending)
		} else if case .active = state {
			close(ending)
		}
	}

	private func expire() async {
		guard case .active = state else { return }
		state = .settling
		host.update(identifier) { $0.expiry = .graceEnded }
		await onExpiry(.graceEnded)
		close(.interrupted(.graceEnded))
	}

	private func close(_ ending: LeaseEnding) {
		if case .ended = state { return }
		state = .ended
		host.update(identifier) { $0.ending = ending }
		if grace != .invalid {
			host.system.endGrace(grace)
			grace = .invalid
		}
	}
}

@MainActor
final class LiveBackgroundSystem: BackgroundSystem {
	func beginGrace(named name: String, expiration: @escaping () -> Void)
		-> UIBackgroundTaskIdentifier
	{
		UIApplication.shared.beginBackgroundTask(withName: name) {
			MainActor.assumeIsolated { expiration() }
		}
	}

	func endGrace(_ identifier: UIBackgroundTaskIdentifier) {
		UIApplication.shared.endBackgroundTask(identifier)
	}
}
