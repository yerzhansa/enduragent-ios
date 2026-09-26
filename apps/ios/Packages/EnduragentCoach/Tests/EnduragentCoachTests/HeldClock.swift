import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class HeldClock: Clock, @unchecked Sendable {
	private let base = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	private let sleepers = Mutex<[Sleeper]>([])

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

	func waitUntilHeld(_ duration: Duration, within limit: Duration = .seconds(5)) async throws {
		let deadline = ContinuousClock.now + limit
		while !held.contains(duration), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(5))
		}
		try #require(held.contains(duration), "no sleeper for \(duration) in \(held)")
	}

	private func resume(_ id: UUID) {
		let sleeper = sleepers.withLock { current -> Sleeper? in
			guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
			return current.remove(at: index)
		}
		sleeper?.wake.resume()
	}
}
