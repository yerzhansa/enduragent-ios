import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct WatchdogTests {
	@Test func cancellingTheTimerDoesNotFire() async throws {
		let clock = HeldClock()
		let watchdog = ChatWatchdog(sleep: clock.sleep)
		await watchdog.arm()
		try await clock.waitUntilHeld(.seconds(30))
		await watchdog.disarm()
		try await waitUntil { clock.held.isEmpty }
		clock.advance(by: .seconds(30))
		#expect(await watchdog.fired() == nil)
		#expect(clock.slept.isEmpty)
	}

	@Test func aBeatRestartsTheInterChunkDeadline() async throws {
		let clock = HeldClock()
		let watchdog = ChatWatchdog(sleep: clock.sleep)
		await watchdog.arm()
		try await clock.waitUntilHeld(.seconds(30))
		clock.advance(by: .seconds(29))
		await watchdog.beat()
		try await clock.waitUntilHeld(.seconds(30))
		clock.advance(by: .seconds(1))
		#expect(clock.slept.isEmpty)
		clock.advance(by: .seconds(29))
		#expect(await watchdog.fired() == .interChunk)
	}
}
