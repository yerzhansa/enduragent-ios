import Foundation
import Synchronization

public protocol Clock: Sendable {
	var now: Date { get }
	var timeZone: TimeZone { get }
	var uptime: Duration { get }
	func sleep(for duration: Duration) async throws
}

public struct SystemClock: Clock {
	public init() {}

	public var now: Date { Date() }
	public var timeZone: TimeZone { .current }
	public var uptime: Duration { ContinuousClock().systemEpoch.duration(to: .now) }

	public func sleep(for duration: Duration) async throws {
		try await Task.sleep(for: duration)
	}
}

public final class FixedClock: Clock {
	public let timeZone: TimeZone
	private let state: Mutex<State>

	private struct State {
		var now: Date
		var uptime: Duration
		var slept: [Duration]
	}

	public init(now: String, timeZone: String) {
		self.timeZone = TimeZone(identifier: timeZone) ?? .gmt
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
		let start = formatter.date(from: now) ?? Date(timeIntervalSince1970: 0)
		self.state = Mutex(State(now: start, uptime: .zero, slept: []))
	}

	public var now: Date {
		state.withLock { $0.now }
	}

	public var uptime: Duration {
		state.withLock { $0.uptime }
	}

	public var slept: [Duration] {
		state.withLock { $0.slept }
	}

	public func advance(by interval: TimeInterval) {
		state.withLock { current in
			current.now = current.now.addingTimeInterval(interval)
			current.uptime += .milliseconds(Int64((interval * 1_000).rounded()))
		}
	}

	public func sleep(for duration: Duration) async throws {
		try Task.checkCancellation()
		state.withLock { current in
			current.slept.append(duration)
			current.now = current.now.addingTimeInterval(duration.timeInterval)
			current.uptime += duration
		}
	}
}
