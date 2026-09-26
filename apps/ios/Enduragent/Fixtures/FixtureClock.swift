import EnduragentCoach
import Foundation

struct FixtureClock: Clock {
	let calendar: FixedClock
	private let system = SystemClock()

	init(calendar: FixedClock) {
		self.calendar = calendar
	}

	var now: Date { calendar.now }
	var timeZone: TimeZone { calendar.timeZone }
	var uptime: Duration { system.uptime }

	func sleep(for duration: Duration) async throws {
		try await system.sleep(for: duration)
	}
}
