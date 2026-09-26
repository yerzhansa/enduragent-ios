import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct WatchdogTests {
	@Test func cancellingTheTimerDoesNotFire() async {
		let watchdog = ChatWatchdog()
		await watchdog.arm()
		await watchdog.disarm()
		let outcome = await watchdog.fired()
		#expect(outcome == nil)
	}

	@Test func pauseForToolsSuppressesFireUntilCleared() async {
		let watchdog = ChatWatchdog()
		await watchdog.arm()
		await watchdog.pauseForTools(["call-1"])
		try? await Task.sleep(for: .milliseconds(80))
		await watchdog.disarm()
		let afterDisarm = await watchdog.fired()
		#expect(afterDisarm == nil)
	}

	@Test func neverEmittingTransportFailsTheTurn() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let coach = makeCoach(transport: transport, store: InMemoryRecordLog())
		let settled = try await coach.sendAndSettle("Hello", within: .seconds(60))
		#expect(failure(settled) == .model(.providerDown(.timeout)))
	}
}
