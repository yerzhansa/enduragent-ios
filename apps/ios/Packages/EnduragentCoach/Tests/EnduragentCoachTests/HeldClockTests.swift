import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct HeldClockTests {
	@Test func advancingWakesOnlyDueSleepsAndMovesTimeOnce() async throws {
		let clock = HeldClock()
		let first = Task { try await clock.sleep(for: .seconds(2)) }
		let second = Task { try await clock.sleep(for: .seconds(5)) }
		try await clock.waitUntilHeld(.seconds(2))
		try await clock.waitUntilHeld(.seconds(5))
		clock.advance(by: .seconds(2))
		try await first.value
		#expect(clock.held == [.seconds(5)])
		#expect(clock.uptime == .seconds(2))
		clock.advance(by: .seconds(3))
		try await second.value
		#expect(clock.held.isEmpty)
		#expect(clock.slept == [.seconds(2), .seconds(5)])
		#expect(clock.uptime == .seconds(5))
	}

	@Test func cancellationUnparksWithoutAdvancingTime() async throws {
		let clock = HeldClock()
		let sleeping = Task { try await clock.sleep(for: .seconds(7)) }
		try await clock.waitUntilHeld(.seconds(7))
		sleeping.cancel()
		await #expect(throws: CancellationError.self) { try await sleeping.value }
		#expect(clock.held.isEmpty)
		#expect(clock.slept.isEmpty)
		#expect(clock.uptime == .zero)
	}

	@Test func releaseAtTheSleepNotificationCannotBeLost() async throws {
		let entered = Gate()
		let clock = HeldClock { _ in entered.release() }
		let sleeping = Task { try await clock.sleep(for: .seconds(7)) }
		await entered.wait()
		clock.release(.seconds(7))
		try await sleeping.value
		#expect(clock.slept == [.seconds(7)])
	}
}
