import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class HeldClock: Clock, @unchecked Sendable {
	private let base = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	private let sleepers = Mutex<[Sleeper]>([])
	private let onSleep: @Sendable (Duration) -> Void

	init(onSleep: @escaping @Sendable (Duration) -> Void = { _ in }) {
		self.onSleep = onSleep
	}

	private struct Sleeper: Sendable {
		let id: UUID
		let duration: Duration
		let wake: CheckedContinuation<Void, Never>
	}

	var now: Date { base.now }
	var timeZone: TimeZone { base.timeZone }
	var uptime: Duration { base.uptime }

	var held: [Duration] {
		sleepers.withLock { $0.map(\.duration) }
	}

	func sleep(for duration: Duration) async throws {
		let id = UUID()
		await withTaskCancellationHandler {
			await withCheckedContinuation { wake in
				sleepers.withLock { $0.append(Sleeper(id: id, duration: duration, wake: wake)) }
				onSleep(duration)
				if Task.isCancelled {
					resume(id)
				}
			}
		} onCancel: {
			resume(id)
		}
		try Task.checkCancellation()
		base.advance(by: duration.timeInterval)
	}

	func release(_ duration: Duration) {
		let woken = sleepers.withLock { current in
			let matching = current.filter { $0.duration == duration }
			current.removeAll { $0.duration == duration }
			return matching
		}
		for sleeper in woken {
			sleeper.wake.resume()
		}
	}

	func waitUntilHeld(_ duration: Duration) async throws {
		let deadline = ContinuousClock.now + .seconds(30)
		while !held.contains(duration) {
			guard ContinuousClock.now < deadline else {
				Issue.record("HeldClock never held \(duration); held sleeps: \(held)")
				throw CancellationError()
			}
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	private func resume(_ id: UUID) {
		let sleeper = sleepers.withLock { current -> Sleeper? in
			guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
			return current.remove(at: index)
		}
		sleeper?.wake.resume()
	}
}
