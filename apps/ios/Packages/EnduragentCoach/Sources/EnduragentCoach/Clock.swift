import Foundation

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
